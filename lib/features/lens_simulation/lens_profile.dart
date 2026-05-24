import 'package:flutter/material.dart';

enum LensProfile {
  noctilux50,
  summilux28,
  summilux35,
}

extension LensProfileInfo on LensProfile {
  String get displayName => switch (this) {
        LensProfile.noctilux50 => 'Noctilux-M 50',
        LensProfile.summilux28 => 'Summilux-M 28',
        LensProfile.summilux35 => 'Summilux-M 35',
      };

  String get shortName => switch (this) {
        LensProfile.noctilux50 => '50mm',
        LensProfile.summilux28 => '28mm',
        LensProfile.summilux35 => '35mm',
      };

  String get apertureSpec => switch (this) {
        LensProfile.noctilux50 => 'f/1.2',
        LensProfile.summilux28 => 'f/1.4',
        LensProfile.summilux35 => 'f/1.4',
      };

  double get maxAperture => switch (this) {
        LensProfile.noctilux50 => 1.2,
        LensProfile.summilux28 => 1.4,
        LensProfile.summilux35 => 1.4,
      };

  String get vignetteAssetPath => switch (this) {
        LensProfile.noctilux50 => 'assets/lens_profiles/noctilux_50_vignette.png',
        LensProfile.summilux28 => 'assets/lens_profiles/summilux_28_vignette.png',
        LensProfile.summilux35 => 'assets/lens_profiles/summilux_35_vignette.png',
      };

  /// Barrel distortion coefficient k1 (negative = barrel, positive = pincushion)
  double get distortionK1 => switch (this) {
        LensProfile.noctilux50 => -0.012,
        LensProfile.summilux28 => -0.058,
        LensProfile.summilux35 => -0.028,
      };

  /// Vignetting strength at max aperture (0=none, 1=full black corners)
  double get vignetteStrength => switch (this) {
        LensProfile.noctilux50 => 0.55,
        LensProfile.summilux35 => 0.35,
        LensProfile.summilux28 => 0.20,
      };

  /// Subtle color tint applied to the live preview to distinguish lenses visually.
  Color get previewTint => switch (this) {
        LensProfile.noctilux50 => const Color(0x35FF9000), // warm amber — cinematic 50mm feel
        LensProfile.summilux35 => const Color(0x1AFFD580), // warm gold
        LensProfile.summilux28 => const Color(0x2800B4D8), // cool blue-cyan — wide-angle clarity
      };

  /// Chromatic aberration fringe width (pixels at 4K)
  double get caFringePixels => switch (this) {
        LensProfile.noctilux50 => 3.5,
        LensProfile.summilux28 => 2.8,
        LensProfile.summilux35 => 2.2,
      };

  /// Bokeh shape — number of aperture blades
  int get apertureBlades => switch (this) {
        LensProfile.noctilux50 => 11,
        LensProfile.summilux28 => 9,
        LensProfile.summilux35 => 9,
      };

  /// Equivalent zoom level relative to the phone's native wide lens.
  /// A phone sensor is roughly 26-28mm equivalent, so:
  ///   28mm → 1.0× (native wide, no zoom)
  ///   35mm → 1.3× (slight telephoto pull-in)
  ///   50mm → 1.8× (clear zoom-in, noticeably tighter frame)
  double get defaultZoom => switch (this) {
        LensProfile.summilux28 => 1.0,
        LensProfile.summilux35 => 1.3,
        LensProfile.noctilux50 => 1.8,
      };

  /// 35mm-equivalent focal length written into EXIF.
  /// summilux28 uses defaultZoom=1.0 which on iPhone 13/14/15 equals 26mm.
  int get focalLengthMm => switch (this) {
        LensProfile.summilux28 => 26,
        LensProfile.summilux35 => 35,
        LensProfile.noctilux50 => 50,
      };

  Color get uiColor => switch (this) {
        LensProfile.noctilux50 => const Color(0xFFD4A853),
        LensProfile.summilux28 => const Color(0xFF7ABFCC),
        LensProfile.summilux35 => const Color(0xFFB8C4A0),
      };
}
