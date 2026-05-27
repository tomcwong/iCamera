#include "icamera_native.h"
#include <cstdint>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>

extern "C" {

// Separable Gaussian bokeh blur with three quality improvements over v1:
//
//  1. Mask feathering  — blurs the segmentation mask itself (radius 6) before
//     use. This smooths the hard pixel-classification edges from the ML model
//     so the subject/background transition is gradual, not a cut-out line.
//
//  2. Foreground-aware sampling  — when blurring a background/edge pixel, the
//     contribution of any neighbour that is MORE foreground than the current
//     pixel is down-weighted by (nm - m). This kills the bright "halo" ring
//     caused by sharp subject colours bleeding into the blurred background.
//
//  3. Soft blend with no hard threshold  — the final composite is
//     dst = src * m + blurred * (1 - m)  for every pixel (m from feathered
//     mask). No binary cut at 0.85 any more; every edge pixel is a mix.
//
// mask: float32, same pixel count as rgba. 1=subject/sharp, 0=background/blur.
// radius: blur radius in pixels (1..55)
void apply_bokeh_blur(
    const uint8_t* src,
    uint8_t* dst,
    const float* mask,
    int width,
    int height,
    int radius
) {
    if (radius < 1) {
        memcpy(dst, src, (size_t)width * height * 4);
        return;
    }

    const int pixels = width * height;

    // ── Step 1: Feather the segmentation mask ────────────────────────────────
    // A 13-tap Gaussian (sigma=4) softens the ML hard edges so blend is smooth.
    const int MR = 6;
    const int MK = MR * 2 + 1;
    float mKernel[MK];
    {
        float mSigma = 4.0f, mSum = 0;
        for (int i = 0; i < MK; i++) {
            float x = (float)(i - MR);
            mKernel[i] = expf(-x * x / (2.0f * mSigma * mSigma));
            mSum += mKernel[i];
        }
        for (int i = 0; i < MK; i++) mKernel[i] /= mSum;
    }

    std::vector<float> tmpMask(pixels), fMask(pixels);

    // Horizontal feather pass
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float v = 0;
            for (int k = 0; k < MK; k++) {
                int sx = std::clamp(x + k - MR, 0, width - 1);
                v += mask[y * width + sx] * mKernel[k];
            }
            tmpMask[y * width + x] = v;
        }
    }
    // Vertical feather pass
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float v = 0;
            for (int k = 0; k < MK; k++) {
                int sy = std::clamp(y + k - MR, 0, height - 1);
                v += tmpMask[sy * width + x] * mKernel[k];
            }
            fMask[y * width + x] = v;
        }
    }

    // ── Step 2: Build main blur kernel ───────────────────────────────────────
    // Wider sigma (radius / 1.5 vs old radius / 2) gives softer, more
    // natural falloff — looks less like a Gaussian ring, more like a real lens.
    const int ksize = radius * 2 + 1;
    std::vector<float> kernel(ksize);
    {
        float sigma = (float)radius / 1.5f;
        float ksum = 0;
        for (int i = 0; i < ksize; i++) {
            float x = (float)(i - radius);
            kernel[i] = expf(-x * x / (2.0f * sigma * sigma));
            ksum += kernel[i];
        }
        for (auto& v : kernel) v /= ksum;
    }

    // ── Step 3: Horizontal pass with foreground-aware sampling ───────────────
    std::vector<uint8_t> temp((size_t)pixels * 4);

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float m = fMask[y * width + x];
            int base = (y * width + x) * 4;

            if (m >= 0.99f) {
                // Deep subject — copy straight through
                temp[base]   = src[base];
                temp[base+1] = src[base+1];
                temp[base+2] = src[base+2];
                temp[base+3] = src[base+3];
                continue;
            }

            // Background or edge: foreground-aware weighted sum.
            // Neighbours that are MORE foreground than this pixel get their
            // kernel weight reduced by the mask difference, preventing halo.
            float r = 0, g = 0, b = 0, a = 0, wTot = 0;
            for (int k = 0; k < ksize; k++) {
                int sx = std::clamp(x + k - radius, 0, width - 1);
                int si = (y * width + sx) * 4;
                float nm = fMask[y * width + sx];
                float kw = kernel[k] * (1.0f - std::max(0.0f, nm - m));
                r += src[si]   * kw;
                g += src[si+1] * kw;
                b += src[si+2] * kw;
                a += src[si+3] * kw;
                wTot += kw;
            }
            if (wTot > 0.0f) { float inv = 1.0f / wTot; r*=inv; g*=inv; b*=inv; a*=inv; }
            temp[base]   = (uint8_t)std::clamp(r, 0.0f, 255.0f);
            temp[base+1] = (uint8_t)std::clamp(g, 0.0f, 255.0f);
            temp[base+2] = (uint8_t)std::clamp(b, 0.0f, 255.0f);
            temp[base+3] = (uint8_t)std::clamp(a, 0.0f, 255.0f);
        }
    }

    // ── Step 4: Vertical pass + soft-mask composite ──────────────────────────
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            float m = fMask[y * width + x];
            int base = (y * width + x) * 4;

            if (m >= 0.99f) {
                dst[base]   = temp[base];
                dst[base+1] = temp[base+1];
                dst[base+2] = temp[base+2];
                dst[base+3] = temp[base+3];
                continue;
            }

            float r = 0, g = 0, b = 0, a = 0, wTot = 0;
            for (int k = 0; k < ksize; k++) {
                int sy = std::clamp(y + k - radius, 0, height - 1);
                int sb = (sy * width + x) * 4;
                float nm = fMask[sy * width + x];
                float kw = kernel[k] * (1.0f - std::max(0.0f, nm - m));
                r += temp[sb]   * kw;
                g += temp[sb+1] * kw;
                b += temp[sb+2] * kw;
                a += temp[sb+3] * kw;
                wTot += kw;
            }
            if (wTot > 0.0f) { float inv = 1.0f / wTot; r*=inv; g*=inv; b*=inv; a*=inv; }

            // Final composite: subject (m=1) fully sharp, background (m=0) fully blurred.
            float blend = 1.0f - m;
            dst[base]   = (uint8_t)(src[base]   * m + std::clamp(r, 0.0f, 255.0f) * blend);
            dst[base+1] = (uint8_t)(src[base+1] * m + std::clamp(g, 0.0f, 255.0f) * blend);
            dst[base+2] = (uint8_t)(src[base+2] * m + std::clamp(b, 0.0f, 255.0f) * blend);
            dst[base+3] = src[base+3];
        }
    }
}

} // extern "C"
