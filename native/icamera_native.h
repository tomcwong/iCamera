#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── image_pipeline.cpp ──────────────────────────────────────────────────────

void apply_white_balance(uint8_t* rgba, int pixel_count,
                         float r_gain, float g_gain, float b_gain);

void apply_exposure(uint8_t* rgba, int pixel_count, float ev_stops);

void apply_tone_curve(uint8_t* rgba, int pixel_count,
                      float contrast, float highlights_rolloff);

void kelvin_to_gains(int kelvin,
                     float* r_out, float* g_out, float* b_out);

// ── lut_engine.cpp ──────────────────────────────────────────────────────────

void apply_3d_lut(uint8_t* rgba, int pixel_count,
                  const float* lut, int grid_size);

void to_greyscale(uint8_t* rgba, int pixel_count);

// ── lens_sim.cpp ────────────────────────────────────────────────────────────

void apply_vignette(uint8_t* rgba, int width, int height, float strength);

void apply_chromatic_aberration(const uint8_t* src, uint8_t* dst,
                                int width, int height, float fringe);

void apply_distortion(const uint8_t* src, uint8_t* dst,
                      int width, int height, float k1);

// ── bokeh_kernel.cpp ────────────────────────────────────────────────────────

void apply_bokeh_blur(const uint8_t* src, uint8_t* dst,
                      const float* mask,
                      int width, int height, int radius);

#ifdef __cplusplus
}
#endif
