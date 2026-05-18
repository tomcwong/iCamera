import 'dart:io';
import 'package:flutter/services.dart';

/// Dart wrapper for [ManualCameraPlugin] (Android only).
///
/// Provides direct hardware ISO and shutter-speed control via CameraX
/// Camera2 interop. All methods silently no-op on iOS and desktop.
class ManualCameraService {
  ManualCameraService._();
  static final ManualCameraService instance = ManualCameraService._();

  static const _ch = MethodChannel('com.tcw3.icamera/manual_camera');

  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Call once after [CameraController.initialize] so we can attach to the
  /// same ProcessCameraProvider the Flutter camera plugin uses.
  /// [front] = true when the front camera is active.
  Future<void> bindControl({bool front = false}) async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('bindControl', {'front': front});
    } catch (_) {}
  }

  /// Lock ISO to [iso] and shutter speed to 1/[shutterDenom] seconds.
  /// Disables the camera's auto-exposure algorithm for the duration.
  Future<void> setManualExposure({
    required int iso,
    required int shutterDenom,
  }) async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('setManualExposure', {
        'iso': iso,
        'shutterDenom': shutterDenom,
      });
    } catch (_) {}
  }

  /// Restore auto-exposure. Clears all Camera2 overrides.
  Future<void> setAutoExposure() async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('setAutoExposure');
    } catch (_) {}
  }

  /// Open the device's system gallery app.
  Future<void> openGallery() async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('openGallery');
    } catch (_) {}
  }
}
