abstract final class AppConstants {
  // Asset paths
  static const lutsPath = 'assets/luts';
  static const lensProfilesPath = 'assets/lens_profiles';
  static const modelsPath = 'assets/models';

  static const segmentationModelPath = '$modelsPath/selfie_segmentation.tflite';
  static const depthModelPath = '$modelsPath/depth_estimation.tflite';

  // Capture defaults
  static const defaultIso = 100;
  static const defaultShutterSpeedDenominator = 60; // 1/60s
  static const defaultAperture = 5.6;

  // Bokeh
  static const minAperture = 1.2;
  static const maxAperture = 16.0;
  static const bokehInputSize = 256; // pixels for segmentation model

  // LUT
  static const lutGridSize = 33; // 33^3 LUT

  // Preview
  static const previewAspectRatio = 4.0 / 3.0;
}
