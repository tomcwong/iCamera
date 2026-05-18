#include "icamera_native.h"
#include <cstdint>
#include <cmath>
#include <algorithm>

extern "C" {

// Apply a 3D LUT (float32 table, size grid^3 * 3, values 0..1) to RGBA bytes.
// grid_size: typically 33
void apply_3d_lut(
    uint8_t* rgba,
    int pixel_count,
    const float* lut,
    int grid_size
) {
    int n = grid_size - 1;
    int gs = grid_size;

    auto idx = [gs](int r, int g, int b) { return (r + g * gs + b * gs * gs) * 3; };

    auto lerp = [](float a, float b, float t) { return a + (b - a) * t; };

    for (int i = 0; i < pixel_count; i++) {
        int base = i * 4;
        float r = rgba[base]     / 255.0f;
        float g = rgba[base + 1] / 255.0f;
        float b = rgba[base + 2] / 255.0f;

        int ri = (int)(r * n); ri = std::min(ri, n - 1);
        int gi = (int)(g * n); gi = std::min(gi, n - 1);
        int bi = (int)(b * n); bi = std::min(bi, n - 1);
        float rf = r * n - ri;
        float gf = g * n - gi;
        float bf = b * n - bi;

        for (int ch = 0; ch < 3; ch++) {
            float v = lerp(
                lerp(
                    lerp(lut[idx(ri,   gi,   bi  ) + ch], lut[idx(ri+1, gi,   bi  ) + ch], rf),
                    lerp(lut[idx(ri,   gi+1, bi  ) + ch], lut[idx(ri+1, gi+1, bi  ) + ch], rf),
                    gf
                ),
                lerp(
                    lerp(lut[idx(ri,   gi,   bi+1) + ch], lut[idx(ri+1, gi,   bi+1) + ch], rf),
                    lerp(lut[idx(ri,   gi+1, bi+1) + ch], lut[idx(ri+1, gi+1, bi+1) + ch], rf),
                    gf
                ),
                bf
            );
            rgba[base + ch] = (uint8_t)(std::clamp(v, 0.0f, 1.0f) * 255.0f);
        }
    }
}

// Convert RGBA to greyscale (luminance-preserving, BT.709 coefficients).
void to_greyscale(uint8_t* rgba, int pixel_count) {
    for (int i = 0; i < pixel_count; i++) {
        int b = i * 4;
        uint8_t lum = (uint8_t)(0.2126f * rgba[b] + 0.7152f * rgba[b+1] + 0.0722f * rgba[b+2]);
        rgba[b] = rgba[b+1] = rgba[b+2] = lum;
    }
}

} // extern "C"
