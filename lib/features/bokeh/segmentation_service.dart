import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final segmentationServiceProvider = Provider<SegmentationService>((ref) {
  return SegmentationService();
});

/// Selfie segmentation stub — ML Kit removed to stabilise the iOS build.
/// Always returns null; the pipeline falls back to a centre-weighted mask.
class SegmentationService {
  Future<Float32List?> segment(File imageFile) async => null;
  void dispose() {}
}
