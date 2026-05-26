import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models/capture_settings.dart';
import '../../services/manual_camera_service.dart';

final availableCamerasProvider = FutureProvider<List<CameraDescription>>((ref) async {
  return await availableCameras();
});

final cameraControllerProvider = StateNotifierProvider<CameraControllerNotifier, AsyncValue<CameraController?>>((ref) {
  return CameraControllerNotifier(ref);
});

class CameraControllerNotifier extends StateNotifier<AsyncValue<CameraController?>> {
  CameraControllerNotifier(Ref ref) : super(const AsyncValue.loading()) {
    initialize();
  }
  CameraController? _controller;
  List<CameraDescription> _allCameras = [];
  // iOS: always use max (AVCaptureSessionPresetPhoto = full 4:3 sensor, ~12MP).
  // veryHigh on iOS maps to AVCaptureSessionPreset1920x1080 which crops the
  // sensor to 16:9, giving a narrower portrait FOV than the native camera app.
  ResolutionPreset _preset =
      Platform.isIOS ? ResolutionPreset.max : ResolutionPreset.veryHigh;

  Future<void> initialize() async {
    try {
      final cameras = await availableCameras();
      _allCameras = cameras;
      if (cameras.isEmpty) {
        state = AsyncValue.error('No cameras found', StackTrace.current);
        return;
      }
      // Default to rear camera
      final rear = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      await _initController(rear);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> _initController(CameraDescription camera) async {
    await _controller?.dispose();
    final controller = CameraController(
      camera,
      _preset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = controller;
    await controller.initialize();
    await controller.setExposureMode(ExposureMode.auto);
    await controller.setFocusMode(FocusMode.auto);
    state = AsyncValue.data(controller);

    // Attach Camera2 interop so manual ISO/shutter can be applied later.
    await ManualCameraService.instance.bindControl(
      front: camera.lensDirection == CameraLensDirection.front,
    );
  }

  /// Set zoom level, clamped to hardware min/max. Returns the applied value.
  /// On iOS, switches between the ultrawide and wide physical cameras to support
  /// 0.5× because the wide camera's minimum zoom is 1.0.
  Future<double> setZoomLevel(double zoom) async {
    if (Platform.isIOS && _allCameras.isNotEmpty) {
      final ctrl = _controller;
      if (ctrl != null) {
        final isUltrawide =
            ctrl.description.name.toLowerCase().contains('ultra');
        if (zoom < 1.0 && !isUltrawide) {
          final uw = _allCameras.firstWhere(
            (c) =>
                c.lensDirection == CameraLensDirection.back &&
                c.name.toLowerCase().contains('ultra'),
            orElse: () => ctrl.description,
          );
          if (uw.name != ctrl.description.name) {
            try {
              state = const AsyncValue.loading();
              await _initController(uw);
              return 0.5;
            } catch (_) {
              // Ultrawide init failed — fall through, zoom will be clamped to 1.0
            }
          }
          // Ultrawide not found or failed; fall through to clamp
        }
        if (zoom >= 1.0 && isUltrawide) {
          final wide = _allCameras.firstWhere(
            (c) =>
                c.lensDirection == CameraLensDirection.back &&
                !c.name.toLowerCase().contains('ultra'),
            orElse: () => ctrl.description,
          );
          if (wide.name != ctrl.description.name) {
            state = const AsyncValue.loading();
            await _initController(wide);
          }
        }
      }
    }
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return zoom;
    try {
      final min = await ctrl.getMinZoomLevel();
      final max = await ctrl.getMaxZoomLevel();
      final clamped = zoom.clamp(min, max).toDouble();
      await ctrl.setZoomLevel(clamped);
      return clamped;
    } catch (_) {
      return zoom;
    }
  }

  Future<void> setQuality(CaptureQuality quality) async {
    _preset = (Platform.isIOS || quality == CaptureQuality.high)
        ? ResolutionPreset.max
        : ResolutionPreset.veryHigh;
    final camera = _controller?.description;
    if (camera == null) return;
    state = const AsyncValue.loading();
    await _initController(camera);
  }

  Future<void> switchCamera() async {
    final cameras = await availableCameras();
    if (cameras.length < 2) return;
    final current = _controller?.description;
    final next = cameras.firstWhere(
      (c) => c.lensDirection != current?.lensDirection,
      orElse: () => cameras.first,
    );
    state = const AsyncValue.loading();
    await _initController(next);
  }

  Future<void> applyManualSettings(CaptureSettings settings) async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    if (settings.mode == CaptureMode.manual) {
      await ctrl.setFocusMode(FocusMode.locked);

      // EV-offset fallback: map ISO → exposure bias relative to ISO 100 baseline.
      // This is guaranteed visible even when Camera2 interop is unavailable.
      // ISO 400 = +2 EV (4× brighter), ISO 800 = +3 EV, ISO 50 = -1 EV, etc.
      final double isoEv = math.log(settings.iso / 100) / math.ln2;
      final double minEv = await ctrl.getMinExposureOffset();
      final double maxEv = await ctrl.getMaxExposureOffset();
      final double evOffset = isoEv.clamp(minEv, maxEv).toDouble();
      await ctrl.setExposureMode(ExposureMode.locked);
      await ctrl.setExposureOffset(evOffset);

      // Camera2 true hardware ISO + shutter (takes precedence if it works).
      await ManualCameraService.instance.setManualExposure(
        iso: settings.iso,
        shutterDenom: settings.shutterSpeedDenominator,
      );
    } else {
      await ctrl.setExposureMode(ExposureMode.auto);
      await ctrl.setFocusMode(FocusMode.auto);
      // Clear Camera2 overrides so auto-exposure fully resumes.
      await ManualCameraService.instance.setAutoExposure();
    }
  }

  Future<XFile?> capture() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return null;
    if (ctrl.value.isTakingPicture) return null;
    return await ctrl.takePicture();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
