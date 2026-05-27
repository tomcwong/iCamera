import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/manual_camera_service.dart';

final segmentationServiceProvider = Provider<SegmentationService>((ref) {
  return SegmentationService();
});

/// Person segmentation for bokeh depth-of-field simulation.
///
/// On iOS (16.0+): uses VNGeneratePersonSegmentationRequest via native channel.
/// Returns null when no person is detected — the C++ pipeline skips bokeh.
/// On Android: always returns null (no segmentation model available without ML Kit).
class SegmentationService {
  Future<Float32List?> segment(File imageFile, int width, int height) async {
    final mask = await ManualCameraService.instance
        .getPersonMask(imageFile.path, width, height);
    if (mask != null && mask.length == width * height) return mask;
    return null;
  }

  void dispose() {}
}
