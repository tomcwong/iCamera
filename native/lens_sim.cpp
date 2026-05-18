#include "icamera_native.h"
#include <cstdint>
#include <cmath>
#include <algorithm>

extern "C" {

// Apply radial vignetting (cosine^4 model) directly to RGBA bytes.
// strength: 0=none, 1=full black corners
void apply_vignette(uint8_t* rgba, int width, int height, float strength) {
    float cx = width  / 2.0f;
    float cy = height / 2.0f;
    float max_r = sqrtf(cx * cx + cy * cy);

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float dx = (x - cx) / max_r;
            float dy = (y - cy) / max_r;
            float r = sqrtf(dx * dx + dy * dy);
            float cos_angle = cosf(r * 3.14159265f / 2.0f);
            float cos4 = cos_angle * cos_angle * cos_angle * cos_angle;
            float w = 1.0f - strength * (1.0f - cos4);
            w = std::clamp(w, 0.0f, 1.0f);

            int base = (y * width + x) * 4;
            rgba[base]     = (uint8_t)(rgba[base]     * w);
            rgba[base + 1] = (uint8_t)(rgba[base + 1] * w);
            rgba[base + 2] = (uint8_t)(rgba[base + 2] * w);
        }
    }
}

// Apply lateral chromatic aberration (red/blue channel shift).
// fringe: shift in pixels for R and B channels (opposite directions).
void apply_chromatic_aberration(
    const uint8_t* src, uint8_t* dst,
    int width, int height,
    float fringe
) {
    float cx = width  / 2.0f;
    float cy = height / 2.0f;
    float max_r = sqrtf(cx * cx + cy * cy);

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float dx = (x - cx) / max_r;
            float dy = (y - cy) / max_r;
            float r  = sqrtf(dx * dx + dy * dy);
            float scale = fringe * r;

            // Shift red outward, blue inward
            auto sample = [&](float sx, float sy, int ch) -> uint8_t {
                int px = (int)std::clamp(sx, 0.0f, (float)(width  - 1));
                int py = (int)std::clamp(sy, 0.0f, (float)(height - 1));
                return src[(py * width + px) * 4 + ch];
            };

            float nx = dx / (r + 1e-6f);
            float ny = dy / (r + 1e-6f);
            int base = (y * width + x) * 4;

            dst[base]     = sample(x + nx * scale, y + ny * scale, 0); // R out
            dst[base + 1] = src[base + 1];                              // G unchanged
            dst[base + 2] = sample(x - nx * scale, y - ny * scale, 2); // B in
            dst[base + 3] = src[base + 3];
        }
    }
}

// Barrel/pincushion distortion using radial polynomial model.
// k1 < 0 = barrel, k1 > 0 = pincushion
void apply_distortion(
    const uint8_t* src, uint8_t* dst,
    int width, int height,
    float k1
) {
    float cx = width  / 2.0f;
    float cy = height / 2.0f;
    float max_r = sqrtf(cx * cx + cy * cy);

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float dx = (x - cx) / max_r;
            float dy = (y - cy) / max_r;
            float r2 = dx * dx + dy * dy;
            float scale = 1.0f + k1 * r2;

            float src_x = cx + dx * scale * max_r;
            float src_y = cy + dy * scale * max_r;

            // Bilinear sample
            int x0 = (int)src_x, y0 = (int)src_y;
            int x1 = x0 + 1, y1 = y0 + 1;
            float fx = src_x - x0, fy = src_y - y0;

            int base = (y * width + x) * 4;
            for (int ch = 0; ch < 4; ch++) {
                auto px = [&](int px, int py) -> float {
                    px = std::clamp(px, 0, width  - 1);
                    py = std::clamp(py, 0, height - 1);
                    return src[(py * width + px) * 4 + ch];
                };
                float v = px(x0,y0)*(1-fx)*(1-fy) + px(x1,y0)*fx*(1-fy)
                        + px(x0,y1)*(1-fx)*fy     + px(x1,y1)*fx*fy;
                dst[base + ch] = (uint8_t)std::clamp(v, 0.0f, 255.0f);
            }
        }
    }
}

} // extern "C"
