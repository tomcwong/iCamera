import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

final segmentationServiceProvider = Provider<SegmentationService>((ref) {
  final service = SegmentationService();
  ref.onDispose(service.dispose);
  return service;
});

/// Wraps ML Kit Selfie Segmentation for real-time portrait mask generation.
/// Returns a Float32List confidence mask (0=background, 1=subject).
/// Falls back to null on failure, which triggers pipeline's fallback mask.
class SegmentationService {
  SelfieSegmenter? _segmenter;

  void init() {
    _segmenter ??= SelfieSegmenter(enableRawSizeMask: false);
  }

  Future<Float32List?> segment(InputImage image) async {
    if (_segmenter == null) init();
    try {
      final result = await _segmenter!.processImage(image);
      if (result == null) return null;
      return _extractMask(result);
    } catch (_) {
      return null;
    }
  }

  Float32List? _extractMask(SegmentationMask mask) {
    final confidences = mask.confidences;
    if (confidences.isEmpty) return null;
    final out = Float32List(confidences.length);
    for (int i = 0; i < confidences.length; i++) {
      out[i] = confidences[i].clamp(0.0, 1.0).toDouble();
    }
    return out;
  }

  void dispose() {
    _segmenter?.close();
    _segmenter = null;
  }
}
