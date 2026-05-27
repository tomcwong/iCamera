import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../native/native_processor.dart';
import '../features/color_science/lut_engine.dart';
import '../features/color_science/color_profile.dart';
import '../features/lens_simulation/lens_renderer.dart';
import '../features/bokeh/bokeh_engine.dart';
import '../features/bokeh/segmentation_service.dart';
import '../features/camera/models/capture_settings.dart';

final imagePipelineProvider = Provider<ImagePipeline>((ref) {
  return ImagePipeline(
    native: ref.read(nativeProcessorProvider),
    lutEngine: ref.read(lutEngineProvider),
    bokehEngine: ref.read(bokehEngineProvider),
    segmentation: ref.read(segmentationServiceProvider),
  );
});

/// Orchestrates image processing with native C++ as the primary path
/// and a pure-Dart fallback for simulator / desktop.
class ImagePipeline {
  const ImagePipeline({
    required this.native,
    required this.lutEngine,
    required this.bokehEngine,
    required this.segmentation,
  });

  final NativeProcessor native;
  final LutEngine lutEngine;
  final BokehEngine bokehEngine;
  final SegmentationService segmentation;

  Future<Uint8List> process({
    required Uint8List rgba,
    required int width,
    required int height,
    required CaptureSettings settings,
    Float32List? segmentationMask,
  }) async {
    if (native.isAvailable) {
      // ── Native C++ path — runs in a background isolate so the heavy bokeh
      // kernel (radius=55, ~1.5B ops on 6MP) doesn't freeze the UI thread.
      return NativeProcessor.runInIsolate(
        rgba: rgba,
        width: width,
        height: height,
        settings: settings,
        segmentationMask: segmentationMask,
      );
    }

    // ── Pure-Dart fallback (simulator / desktop) ──────────────────────────
    return _dartFallback(rgba, width, height, settings, segmentationMask);
  }

  Future<Uint8List> _dartFallback(
    Uint8List rgba,
    int width,
    int height,
    CaptureSettings settings,
    Float32List? segmentationMask,
  ) async {
    var pixels = rgba;

    if (settings.leicaLookEnabled) {
      // 1. Colour look (Dart trilinear LUT)
      pixels = lutEngine.apply(settings.selectedLook, pixels);

      // 2. Lens vignetting (Dart)
      final vigMap = LensRenderer.instance.buildVignetteMap(
        width, height, settings.selectedLens, settings.aperture,
      );
      LensRenderer.instance.applyVignette(pixels, vigMap);
    }

    // 3. Bokeh (Dart fallback, PRO mode with wide aperture)
    if (settings.mode == CaptureMode.manual && settings.aperture < 8.0) {
      final mask = segmentationMask ?? _centreWeightedMask(width, height);
      pixels = await bokehEngine.apply(
        rgba: pixels,
        mask: mask,
        width: width,
        height: height,
        aperture: settings.aperture,
        lens: settings.selectedLens,
      );
    }

    return pixels;
  }

  Float32List _centreWeightedMask(int width, int height) {
    final mask = Float32List(width * height);
    final cx = width / 2.0;
    final cy = height / 2.0;
    final maxR2 = (cx * 0.45) * (cx * 0.45);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy);
        mask[y * width + x] = (1.0 - (d2 / maxR2).clamp(0.0, 1.0)).toDouble();
      }
    }
    return mask;
  }
}
