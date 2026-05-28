import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'native_bridge.dart';
import 'lut_cache.dart';
import '../features/camera/models/capture_settings.dart';
import '../features/color_science/lut_engine.dart';
import '../features/lens_simulation/lens_profile.dart';

// Top-level so compute() can reference it. Creates a fresh, disposable
// NativeProcessor inside the background isolate — no Pointers cross isolate
// boundaries, each isolate allocates its own native buffers.
// lutData is the LUT pre-loaded on the main isolate; background isolates cannot
// call rootBundle so the data must be passed in as a plain Float32List.
Future<Uint8List> _runPipelineIsolate(Map<String, dynamic> args) async {
  final proc = NativeProcessor._();
  try {
    return await proc.process(
      rgba: args['rgba'] as Uint8List,
      width: args['width'] as int,
      height: args['height'] as int,
      settings: args['settings'] as CaptureSettings,
      segmentationMask: args['mask'] as Float32List?,
      lutData: args['lutData'] as Float32List?,
    );
  } finally {
    proc.dispose();
  }
}

final nativeProcessorProvider = Provider<NativeProcessor>((ref) {
  final p = NativeProcessor._();
  ref.onDispose(p.dispose);
  return p;
});

/// High-level Dart wrapper around the native C++ image processing pipeline.
///
/// Manages two reusable native pixel buffers (ping-pong) and a float mask
/// buffer. Buffers grow to fit the largest frame seen and are never shrunk —
/// this eliminates repeated calloc/free during real-time capture.
///
/// Operations that require src → dst (CA, distortion, bokeh) alternate the
/// active buffer so the result always lives in [_buf0] or [_buf1] without
/// any extra copies. [_active] tracks which buffer is current.
class NativeProcessor {
  NativeProcessor._();

  final NativeBridge _b = NativeBridge.instance;
  final LutCache _luts = LutCache.instance;

  bool get isAvailable => _b.isLoaded;

  // ── Reusable native memory ───────────────────────────────────────────────

  Pointer<Uint8> _buf0 = nullptr;
  Pointer<Uint8> _buf1 = nullptr;
  Pointer<Float> _maskBuf = nullptr;
  int _bufBytes = 0;
  int _maskCount = 0;
  int _active = 0; // 0 → _buf0 is current, 1 → _buf1 is current

  Pointer<Uint8> get _src => _active == 0 ? _buf0 : _buf1;
  Pointer<Uint8> get _dst => _active == 0 ? _buf1 : _buf0;

  void _flip() => _active = 1 - _active;

  void _ensurePixelBufs(int bytes) {
    if (bytes <= _bufBytes) return;
    if (_buf0 != nullptr) calloc.free(_buf0);
    if (_buf1 != nullptr) calloc.free(_buf1);
    _buf0 = calloc<Uint8>(bytes);
    _buf1 = calloc<Uint8>(bytes);
    _bufBytes = bytes;
    _active = 0;
  }

  void _ensureMaskBuf(int count) {
    if (count <= _maskCount) return;
    if (_maskBuf != nullptr) calloc.free(_maskBuf);
    _maskBuf = calloc<Float>(count);
    _maskCount = count;
  }

  // ── Main pipeline entry point ────────────────────────────────────────────

  /// Runs the full native pipeline on [rgba] RGBA bytes and returns the
  /// processed result. Falls back gracefully if native is unavailable.
  /// [lutData] is the pre-serialised LUT Float32List when running inside a
  /// background isolate (where rootBundle is unavailable). When null, the
  /// LUT is loaded from LutCache as normal (main-isolate path).
  Future<Uint8List> process({
    required Uint8List rgba,
    required int width,
    required int height,
    required CaptureSettings settings,
    Float32List? segmentationMask,
    Float32List? lutData,
  }) async {
    if (!isAvailable) return rgba;

    final pixels = width * height;
    final bytes = pixels * 4;

    _ensurePixelBufs(bytes);
    _active = 0; // always start from _buf0

    // Copy Dart bytes → native src buffer
    _src.asTypedList(bytes).setAll(0, rgba);

    // 1. Colour look (3D LUT) — Leica Look only ─────────────────────────────
    if (settings.leicaLookEnabled) {
      Pointer<Float>? lutPtr;
      bool tempAlloc = false;
      if (lutData != null) {
        // Background isolate: rootBundle unavailable, use pre-loaded Float32List.
        final ptr = calloc<Float>(lutData.length);
        ptr.asTypedList(lutData.length).setAll(0, lutData);
        lutPtr = ptr;
        tempAlloc = true;
      } else {
        lutPtr = await _luts.get(settings.selectedLook);
      }
      if (lutPtr != null) {
        _b.apply3dLut(_src, pixels, lutPtr, 33);
        if (tempAlloc) calloc.free(lutPtr);
      }
    }

    // 2. Exposure compensation — always applied ──────────────────────────────
    if (settings.exposureCompensation != 0.0) {
      _b.applyExposure(_src, pixels, settings.exposureCompensation);
    }

    // 3. White balance — always applied when off neutral ─────────────────────
    if (settings.whiteBalanceKelvin != 5500) {
      _applyKelvin(settings.whiteBalanceKelvin, pixels);
    }

    if (settings.leicaLookEnabled) {
      // 4. Tone curve (film-like contrast + highlight rolloff) ────────────────
      _b.applyToneCurve(_src, pixels, 0.16, 0.88);

      // 5. Lens vignetting ───────────────────────────────────────────────────
      final vStr = _vignetteStrength(settings.selectedLens, settings.aperture);
      _b.applyVignette(_src, width, height, vStr);

      // 6. Chromatic aberration (not in AUTO mode) ──────────────────────────
      if (settings.mode != CaptureMode.auto) {
        final fringe = _caFringe(settings.selectedLens, settings.aperture);
        if (fringe > 0.5) {
          _b.applyCa(_src, _dst, width, height, fringe);
          _flip();
        }
      }

      // 7. Barrel distortion ─────────────────────────────────────────────────
      if (settings.mode != CaptureMode.auto) {
        final k1 = settings.selectedLens.distortionK1;
        if (k1.abs() > 0.001) {
          _b.applyDistortion(_src, _dst, width, height, k1);
          _flip();
        }
      }
    }

    // 8. Bokeh / depth-of-field blur ─────────────────────────────────────────
    if (settings.mode == CaptureMode.manual &&
        settings.aperture < 8.0 &&
        segmentationMask != null) {
      _ensureMaskBuf(pixels);
      _maskBuf.asTypedList(pixels).setAll(0, segmentationMask);
      final radius = _bokehRadius(settings.aperture, settings.selectedLens.maxAperture);
      if (radius > 0) {
        _b.applyBokehBlur(_src, _dst, _maskBuf, width, height, radius);
        _flip();
      }
    }

    // Copy result back to Dart
    return Uint8List.fromList(_src.asTypedList(bytes));
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _applyKelvin(int kelvin, int pixels) {
    final rp = calloc<Float>();
    final gp = calloc<Float>();
    final bp = calloc<Float>();
    _b.kelvinToGains(kelvin, rp, gp, bp);
    _b.applyWhiteBalance(_src, pixels, rp.value, gp.value, bp.value);
    calloc.free(rp);
    calloc.free(gp);
    calloc.free(bp);
  }

  double _vignetteStrength(LensProfile lens, double aperture) {
    final ratio = (lens.maxAperture / aperture).clamp(0.3, 1.0);
    return lens.vignetteStrength * ratio;
  }

  double _caFringe(LensProfile lens, double aperture) {
    return lens.caFringePixels * (lens.maxAperture / aperture).clamp(0.5, 1.0);
  }

  int _bokehRadius(double aperture, double maxAperture) {
    // f/1.0 → 55px, f/1.4 → 39px, f/2.8 → 20px, f/8.0 → 7px
    // Cap raised from 28 to 55 so wide apertures produce visibly strong blur.
    return (55.0 * (maxAperture / aperture)).clamp(0.0, 55.0).round();
  }

  /// Run the full pipeline in a background isolate so the heavy bokeh blur
  /// (radius=55 on 6MP = ~1.5B ops) doesn't freeze the UI thread.
  /// CaptureSettings contains only Dart primitives and enums — safely sendable.
  /// The LUT is pre-loaded here (on the main isolate where rootBundle works)
  /// and passed as a plain Float32List so the background isolate never needs
  /// to call rootBundle.loadString(), which hangs in a compute() isolate.
  static Future<Uint8List> runInIsolate({
    required Uint8List rgba,
    required int width,
    required int height,
    required CaptureSettings settings,
    Float32List? segmentationMask,
  }) async {
    Float32List? lutData;
    if (settings.leicaLookEnabled) {
      await LutEngine.instance.preloadLook(settings.selectedLook);
      lutData = LutEngine.instance.nativeData(settings.selectedLook);
    }
    return compute(_runPipelineIsolate, {
      'rgba': rgba,
      'width': width,
      'height': height,
      'settings': settings,
      'mask': segmentationMask,
      'lutData': lutData,
    });
  }

  void dispose() {
    if (_buf0 != nullptr) { calloc.free(_buf0); _buf0 = nullptr; }
    if (_buf1 != nullptr) { calloc.free(_buf1); _buf1 = nullptr; }
    if (_maskBuf != nullptr) { calloc.free(_maskBuf); _maskBuf = nullptr; }
    _bufBytes = 0;
    _maskCount = 0;
  }
}
