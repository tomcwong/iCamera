#include "icamera_native.h"
#include <cstdint>
#include <cmath>
#include <cstring>
#include <algorithm>

extern "C" {

// ── White balance (multiply R/G/B channels by per-channel gains) ─────────────
void apply_white_balance(uint8_t* rgba, int pixel_count, float r_gain, float g_gain, float b_gain) {
    for (int i = 0; i < pixel_count; i++) {
        int base = i * 4;
        rgba[base]     = (uint8_t)std::min(255.0f, rgba[base]     * r_gain);
        rgba[base + 1] = (uint8_t)std::min(255.0f, rgba[base + 1] * g_gain);
        rgba[base + 2] = (uint8_t)std::min(255.0f, rgba[base + 2] * b_gain);
    }
}

// ── Exposure compensation (power law) ────────────────────────────────────────
void apply_exposure(uint8_t* rgba, int pixel_count, float ev_stops) {
    float gain = powf(2.0f, ev_stops);
    for (int i = 0; i < pixel_count; i++) {
        int base = i * 4;
        for (int c = 0; c < 3; c++) {
            rgba[base + c] = (uint8_t)std::min(255.0f, rgba[base + c] * gain);
        }
    }
}

// ── Tone curve (S-curve for contrast lift) ───────────────────────────────────
// coefficients: midtone = contrast pivot, highlights_rolloff = soft clip
void apply_tone_curve(uint8_t* rgba, int pixel_count, float contrast, float highlights_rolloff) {
    // Precompute 256-entry LUT
    float lut[256];
    for (int i = 0; i < 256; i++) {
        float t = i / 255.0f;
        // Smooth S-curve via 3rd degree polynomial
        float s = t + contrast * t * (1.0f - t) * (t - 0.5f);
        // Highlight rolloff (soft knee above 0.8)
        if (s > highlights_rolloff) {
            float over = s - highlights_rolloff;
            s = highlights_rolloff + over / (1.0f + over / (1.0f - highlights_rolloff));
        }
        lut[i] = std::clamp(s, 0.0f, 1.0f) * 255.0f;
    }

    for (int i = 0; i < pixel_count; i++) {
        int base = i * 4;
        for (int c = 0; c < 3; c++) {
            rgba[base + c] = (uint8_t)lut[rgba[base + c]];
        }
    }
}

// ── Convert Kelvin to RGB gains (approx Tanner Helland algorithm) ────────────
void kelvin_to_gains(int kelvin, float* r_out, float* g_out, float* b_out) {
    float t = kelvin / 100.0f;
    float r, g, b;
    if (t <= 66.0f) {
        r = 255.0f;
        g = 99.4708025861f * logf(t) - 161.1195681661f;
        b = (t <= 19.0f) ? 0.0f : 138.5177312231f * logf(t - 10.0f) - 305.0447927307f;
    } else {
        r = 329.698727446f * powf(t - 60.0f, -0.1332047592f);
        g = 288.1221695283f * powf(t - 60.0f, -0.0755148492f);
        b = 255.0f;
    }
    float ref_r = 255.0f, ref_g = 190.0f, ref_b = 170.0f; // ~5500K daylight baseline
    *r_out = std::clamp(r / ref_r, 0.1f, 4.0f);
    *g_out = std::clamp(g / ref_g, 0.1f, 4.0f);
    *b_out = std::clamp(b / ref_b, 0.1f, 4.0f);
}

} // extern "C"
