import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final depthEstimatorProvider = Provider<DepthEstimator>((ref) {
  final estimator = DepthEstimator();
  ref.onDispose(estimator.dispose);
  return estimator;
});

/// Depth estimation stub — TFLite removed to stabilise the iOS build.
/// Always returns null; bokeh falls back to a centre-weighted mask.
class DepthEstimator {
  Future<void> load() async {}
  Future<Float32List?> estimate(Float32List inputRgb) async => null;
  void dispose() {}
}
