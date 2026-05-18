import 'dart:math' as math;
import 'dart:typed_data';
import 'lens_profile.dart';

/// Applies lens optical character to RGBA pixel data:
/// vignetting, barrel distortion weight map, and chromatic aberration fringe.
class LensRenderer {
  LensRenderer._();
  static final instance = LensRenderer._();

  /// Returns a vignette weight map (Float32, 0..1) for given dimensions and lens.
  Float32List buildVignetteMap(int width, int height, LensProfile lens, double aperture) {
    final map = Float32List(width * height);
    final cx = width / 2.0;
    final cy = height / 2.0;
    final maxR = math.sqrt(cx * cx + cy * cy);

    // Vignette strength scales with aperture: wider = more vignette
    final apertureRatio = (lens.maxAperture / aperture).clamp(0.0, 1.0);
    final strength = lens.vignetteStrength * apertureRatio;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final dx = (x - cx) / maxR;
        final dy = (y - cy) / maxR;
        final r = math.sqrt(dx * dx + dy * dy);
        // Cosine^4 fall-off (natural vignetting law)
        final cos4 = math.pow(math.cos(r * math.pi / 2.0), 4).toDouble();
        map[y * width + x] = (1.0 - strength * (1.0 - cos4)).clamp(0.0, 1.0);
      }
    }
    return map;
  }

  /// Apply vignette weight map to RGBA bytes in-place.
  void applyVignette(Uint8List rgba, Float32List vignetteMap) {
    for (int i = 0; i < vignetteMap.length; i++) {
      final w = vignetteMap[i];
      rgba[i * 4] = (rgba[i * 4] * w).round().clamp(0, 255);
      rgba[i * 4 + 1] = (rgba[i * 4 + 1] * w).round().clamp(0, 255);
      rgba[i * 4 + 2] = (rgba[i * 4 + 2] * w).round().clamp(0, 255);
    }
  }

  /// Build a circular aperture mask for bokeh kernel (polygon with [blades] sides).
  /// Returns a normalized Float32 kernel of size [kernelSize x kernelSize].
  Float32List buildBokehKernel(int kernelSize, LensProfile lens) {
    final kernel = Float32List(kernelSize * kernelSize);
    final cx = (kernelSize - 1) / 2.0;
    final blades = lens.apertureBlades;
    double total = 0;

    for (int y = 0; y < kernelSize; y++) {
      for (int x = 0; x < kernelSize; x++) {
        final dx = (x - cx) / cx;
        final dy = (y - cx) / cx;
        final r = math.sqrt(dx * dx + dy * dy);
        if (r <= 1.0 && _inAperturePolygon(dx, dy, blades)) {
          kernel[y * kernelSize + x] = 1.0;
          total += 1.0;
        }
      }
    }

    // Normalize
    if (total > 0) {
      for (int i = 0; i < kernel.length; i++) {
        kernel[i] /= total;
      }
    }
    return kernel;
  }

  bool _inAperturePolygon(double x, double y, int blades) {
    // Regular polygon test using angular sectors
    final angle = math.atan2(y, x);
    final r = math.sqrt(x * x + y * y);
    if (r == 0) return true;
    final sectorAngle = 2 * math.pi / blades;
    final sector = (angle / sectorAngle).floor();
    final theta = angle - sector * sectorAngle - sectorAngle / 2;
    final maxR = math.cos(math.pi / blades) / math.cos(theta);
    return r <= maxR;
  }
}
