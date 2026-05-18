import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../lens_simulation/lens_profile.dart';
import '../lens_simulation/lens_renderer.dart';

final bokehEngineProvider = Provider<BokehEngine>((ref) => BokehEngine());

class BokehEngine {
  /// Apply depth-of-field blur using a subject mask and bokeh kernel.
  ///
  /// [rgba] - source image bytes (RGBA)
  /// [mask] - subject confidence mask (0=background, 1=subject) Float32
  /// [width], [height] - image dimensions
  /// [aperture] - f-stop value; lower = more blur
  /// [lens] - which lens bokeh shape to use
  Future<Uint8List> apply({
    required Uint8List rgba,
    required Float32List mask,
    required int width,
    required int height,
    required double aperture,
    required LensProfile lens,
  }) async {
    // Kernel size scales inversely with aperture (f/1.2 = large kernel)
    final kernelRadius = _kernelRadius(aperture);
    if (kernelRadius < 1) return rgba;

    final kernelSize = kernelRadius * 2 + 1;
    final kernel = LensRenderer.instance.buildBokehKernel(kernelSize, lens);

    return _convolveWithMask(rgba, mask, width, height, kernel, kernelSize);
  }

  int _kernelRadius(double aperture) {
    // Maps f/1.2 -> radius 32px, f/16 -> radius 0px (at 4K)
    final blur = (32.0 * (1.2 / aperture)).clamp(0.0, 32.0);
    return blur.round();
  }

  Uint8List _convolveWithMask(
    Uint8List rgba,
    Float32List mask,
    int width,
    int height,
    Float32List kernel,
    int kernelSize,
  ) {
    final out = Uint8List.fromList(rgba);
    final kHalf = kernelSize ~/ 2;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final pixIdx = y * width + x;
        final subjectWeight = mask[pixIdx.clamp(0, mask.length - 1)];
        // Only blur background pixels (low subject weight)
        if (subjectWeight > 0.8) continue;
        final blurAmount = 1.0 - subjectWeight;

        double r = 0, g = 0, b = 0;
        for (int ky = 0; ky < kernelSize; ky++) {
          for (int kx = 0; kx < kernelSize; kx++) {
            final sy = (y + ky - kHalf).clamp(0, height - 1);
            final sx = (x + kx - kHalf).clamp(0, width - 1);
            final si = (sy * width + sx) * 4;
            final kw = kernel[ky * kernelSize + kx];
            r += rgba[si] * kw;
            g += rgba[si + 1] * kw;
            b += rgba[si + 2] * kw;
          }
        }

        final oi = pixIdx * 4;
        out[oi] = _blend(rgba[oi], r.round(), blurAmount);
        out[oi + 1] = _blend(rgba[oi + 1], g.round(), blurAmount);
        out[oi + 2] = _blend(rgba[oi + 2], b.round(), blurAmount);
      }
    }
    return out;
  }

  int _blend(int original, int blurred, double amount) {
    return (original * (1 - amount) + blurred * amount).round().clamp(0, 255);
  }
}
