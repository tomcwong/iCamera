import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../../core/constants.dart';

final depthEstimatorProvider = Provider<DepthEstimator>((ref) {
  final estimator = DepthEstimator();
  ref.onDispose(estimator.dispose);
  return estimator;
});

/// Runs a TFLite monocular depth estimation model.
/// Output is a Float32 depth map normalized 0..1 (near..far).
class DepthEstimator {
  Interpreter? _interpreter;
  static const int _inputSize = 256;

  Future<void> load() async {
    _interpreter = await Interpreter.fromAsset(AppConstants.depthModelPath);
  }

  /// [inputRgb] - flattened RGB bytes resized to [_inputSize x _inputSize].
  /// Returns Float32List depth map of length [_inputSize * _inputSize].
  Future<Float32List?> estimate(Float32List inputRgb) async {
    final interp = _interpreter;
    if (interp == null) return null;

    final input = inputRgb.reshape([1, _inputSize, _inputSize, 3]);
    final output = List.filled(1 * _inputSize * _inputSize, 0.0).reshape([1, _inputSize, _inputSize, 1]);

    interp.run(input, output);

    final flat = Float32List(_inputSize * _inputSize);
    for (int i = 0; i < flat.length; i++) {
      flat[i] = (output[0] as List)[i ~/ _inputSize][i % _inputSize][0] as double;
    }
    return flat;
  }

  void dispose() => _interpreter?.close();
}
