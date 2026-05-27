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

  /// Returns the camera's current live exposure values (ISO, shutter, EV).
  /// On iOS reads directly from AVCaptureDevice — works in both AUTO and PRO mode.
  /// Returns null if unavailable.
  Future<Map<String, dynamic>?> getLiveExposure() async {
    if (!isSupported) return null;
    try {
      final raw = await _ch.invokeMethod<Map>('getLiveExposure');
      if (raw == null) return null;
      return Map<String, dynamic>.from(raw);
    } catch (_) {
      return null;
    }
  }

  /// Open the device's system gallery app.
  Future<void> openGallery() async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('openGallery');
    } catch (_) {}
  }

  /// Encodes raw RGBA pixels directly to HEIF (H.265) via native iOS ImageIO.
  /// Avoids any intermediate JPEG step — single lossy encode from processed pixels.
  /// Returns null on Android or on failure (caller should fall back to JPEG).
  Future<Uint8List?> encodePixelsToHeif(
      Uint8List rgba, int width, int height, {double quality = 0.9}) async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _ch.invokeMethod<dynamic>('encodeRgbaToHeif', {
        'rgba': rgba,
        'width': width,
        'height': height,
        'quality': quality,
      });
      if (raw == null) return null;
      if (raw is Uint8List) return raw;
      return Uint8List.fromList((raw as List).cast<int>());
    } catch (_) {
      return null;
    }
  }

  /// Releases the AVCaptureDevice lock held since setManualExposure.
  /// Must be called after ctrl.takePicture() when in PRO mode on iOS.
  Future<void> unlockAfterCapture() async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod<void>('unlockAfterCapture');
    } catch (_) {}
  }

  /// Writes GPS metadata into a JPEG at [path] using native iOS ImageIO.
  /// Uses CGImageDestination to merge the GPS sub-dict without re-running
  /// our image pipeline. No-op on Android (caller uses native_exif instead).
  Future<void> writeGpsToPhoto({
    required String path,
    required double lat,
    required double lon,
    double alt = 0,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod<void>('writeGpsToPhoto', {
        'path': path,
        'lat': lat,
        'lon': lon,
        'alt': alt,
      });
    } catch (_) {}
  }

  /// Captures a single JPEG via native AVCapturePhotoOutput with Smart HDR and
  /// virtual-device fusion disabled, so manual ISO/SS settings are honoured.
  /// Returns null on failure — caller should fall back to ctrl.takePicture().
  Future<Uint8List?> captureProPhoto() async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _ch.invokeMethod<dynamic>('captureProPhoto');
      if (raw == null) return null;
      if (raw is Uint8List) return raw;
      return Uint8List.fromList((raw as List).cast<int>());
    } catch (_) {
      return null;
    }
  }

  /// Returns the optical zoom switch-over factors for the back camera on iOS.
  /// Always includes 1.0. Ultra-wide adds 0.5; telephoto adds 2×/3×/5× etc.
  /// Returns [1.0] on Android or on error.
  Future<List<double>> getAvailableZoomFactors() async {
    if (!Platform.isIOS) return [1.0];
    try {
      final raw = await _ch.invokeMethod<List>('getAvailableZoomFactors');
      if (raw == null || raw.isEmpty) return [1.0];
      return raw.map((e) => (e as num).toDouble()).toList();
    } catch (_) {
      return [1.0];
    }
  }
}
