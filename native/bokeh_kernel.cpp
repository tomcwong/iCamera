#include "icamera_native.h"
#include <cstdint>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>

extern "C" {

// Separable Gaussian blur applied only to pixels with mask < threshold.
// mask: float32, same pixel count as rgba. 1=subject (keep sharp), 0=bg (blur).
// radius: blur radius in pixels (1..32)
void apply_bokeh_blur(
    const uint8_t* src,
    uint8_t* dst,
    const float* mask,
    int width,
    int height,
    int radius
) {
    if (radius < 1) {
        memcpy(dst, src, width * height * 4);
        return;
    }

    int ksize = radius * 2 + 1;
    std::vector<float> kernel(ksize);
    float sigma = radius / 2.0f;
    float sum = 0;
    for (int i = 0; i < ksize; i++) {
        float x = i - radius;
        kernel[i] = expf(-x * x / (2 * sigma * sigma));
        sum += kernel[i];
    }
    for (auto& v : kernel) v /= sum;

    // Horizontal pass → temp
    std::vector<uint8_t> temp(width * height * 4);
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float m = mask[y * width + x];
            if (m > 0.85f) {
                // Subject — copy directly
                int base = (y * width + x) * 4;
                temp[base] = src[base]; temp[base+1] = src[base+1];
                temp[base+2] = src[base+2]; temp[base+3] = src[base+3];
                continue;
            }
            float r = 0, g = 0, b = 0, a = 0;
            for (int k = 0; k < ksize; k++) {
                int sx = std::clamp(x + k - radius, 0, width - 1);
                int base = (y * width + sx) * 4;
                float w = kernel[k];
                r += src[base]   * w;
                g += src[base+1] * w;
                b += src[base+2] * w;
                a += src[base+3] * w;
            }
            int base = (y * width + x) * 4;
            temp[base]   = (uint8_t)std::clamp(r, 0.0f, 255.0f);
            temp[base+1] = (uint8_t)std::clamp(g, 0.0f, 255.0f);
            temp[base+2] = (uint8_t)std::clamp(b, 0.0f, 255.0f);
            temp[base+3] = (uint8_t)std::clamp(a, 0.0f, 255.0f);
        }
    }

    // Vertical pass → dst
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float m = mask[y * width + x];
            int base = (y * width + x) * 4;
            if (m > 0.85f) {
                dst[base] = temp[base]; dst[base+1] = temp[base+1];
                dst[base+2] = temp[base+2]; dst[base+3] = temp[base+3];
                continue;
            }
            float r = 0, g = 0, b = 0, a = 0;
            for (int k = 0; k < ksize; k++) {
                int sy = std::clamp(y + k - radius, 0, height - 1);
                int sb = (sy * width + x) * 4;
                float w = kernel[k];
                r += temp[sb]   * w;
                g += temp[sb+1] * w;
                b += temp[sb+2] * w;
                a += temp[sb+3] * w;
            }
            // Blend with subject mask (soft edge)
            float blend = 1.0f - m;
            dst[base]   = (uint8_t)(src[base]   * m + std::clamp(r, 0.0f, 255.0f) * blend);
            dst[base+1] = (uint8_t)(src[base+1] * m + std::clamp(g, 0.0f, 255.0f) * blend);
            dst[base+2] = (uint8_t)(src[base+2] * m + std::clamp(b, 0.0f, 255.0f) * blend);
            dst[base+3] = src[base+3];
        }
    }
}

} // extern "C"
