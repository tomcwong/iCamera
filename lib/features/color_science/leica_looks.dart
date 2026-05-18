import 'package:flutter/material.dart';
import '../../core/theme/leica_colors.dart';

enum LeicaLook {
  classic,
  contemporary,
  bw,
  vivid,
  artist,
}

extension LeicaLookInfo on LeicaLook {
  String get displayName => switch (this) {
        LeicaLook.classic => 'Classic',
        LeicaLook.contemporary => 'Contemporary',
        LeicaLook.bw => 'B&W',
        LeicaLook.vivid => 'Vivid',
        LeicaLook.artist => 'Artist',
      };

  String get lutAssetPath => switch (this) {
        LeicaLook.classic => 'assets/luts/leica_classic.cube',
        LeicaLook.contemporary => 'assets/luts/leica_contemporary.cube',
        LeicaLook.bw => 'assets/luts/leica_bw.cube',
        LeicaLook.vivid => 'assets/luts/leica_vivid.cube',
        LeicaLook.artist => 'assets/luts/leica_artist.cube',
      };

  String get description => switch (this) {
        LeicaLook.classic => 'Warm, film-like tones with lifted shadows',
        LeicaLook.contemporary => 'Clean contrast with refined highlights',
        LeicaLook.bw => 'Rich monochrome with deep blacks',
        LeicaLook.vivid => 'Punchy, saturated rendering',
        LeicaLook.artist => 'Cinematic mid-tone compression',
      };

  /// 4×5 ColorFilter matrix applied to the live preview to approximate the look.
  /// Format: [r→r, g→r, b→r, a→r, r_offset,  r→g, g→g, b→g, a→g, g_offset,  ...]
  List<double> get previewMatrix => switch (this) {
        LeicaLook.classic => [
          // Warm, slightly desaturated, lifted shadows
          0.90, 0.10, 0.00, 0, 10,
          0.05, 0.95, 0.00, 0,  5,
          0.00, 0.05, 0.82, 0,  0,
          0,    0,    0,    1,  0,
        ],
        LeicaLook.contemporary => [
          // Clean, neutral, slight contrast punch
          1.08, 0,    0,    0, -10,
          0,    1.05, 0,    0,  -8,
          0,    0,    1.02, 0,  -3,
          0,    0,    0,    1,   0,
        ],
        LeicaLook.bw => [
          // Grayscale using luminance weights
          0.25, 0.65, 0.10, 0, -5,
          0.25, 0.65, 0.10, 0, -5,
          0.25, 0.65, 0.10, 0, -5,
          0,    0,    0,    1,  0,
        ],
        LeicaLook.vivid => [
          // High saturation boost (sat factor ~1.5)
           1.39, -0.36, -0.04, 0, 0,
          -0.11,  1.14, -0.04, 0, 0,
          -0.11, -0.36,  1.46, 0, 0,
           0,     0,     0,    1, 0,
        ],
        LeicaLook.artist => [
          // Cinematic: cool, faded/lifted shadows, slight teal push
          0.88, 0.05, 0.02, 0, 15,
          0.02, 0.88, 0.05, 0, 10,
          0.02, 0.08, 0.98, 0, 12,
          0,    0,    0,    1,  0,
        ],
      };

  Color get accentColor => switch (this) {
        LeicaLook.classic => LeicaColors.lookClassic,
        LeicaLook.contemporary => LeicaColors.lookContemporary,
        LeicaLook.bw => LeicaColors.lookBW,
        LeicaLook.vivid => LeicaColors.lookVivid,
        LeicaLook.artist => LeicaColors.lookArtist,
      };
}
