import 'dart:ffi';
import 'dart:io';

// ── C function signatures (Native = C ABI, Dart = Dart call convention) ──────

// image_pipeline.cpp
typedef WbNative = Void Function(Pointer<Uint8>, Int32, Float, Float, Float);
typedef WbFn = void Function(Pointer<Uint8>, int, double, double, double);

typedef ExposureNative = Void Function(Pointer<Uint8>, Int32, Float);
typedef ExposureFn = void Function(Pointer<Uint8>, int, double);

typedef ToneCurveNative = Void Function(Pointer<Uint8>, Int32, Float, Float);
typedef ToneCurveFn = void Function(Pointer<Uint8>, int, double, double);

typedef KelvinNative = Void Function(Int32, Pointer<Float>, Pointer<Float>, Pointer<Float>);
typedef KelvinFn = void Function(int, Pointer<Float>, Pointer<Float>, Pointer<Float>);

// lut_engine.cpp
typedef LutNative = Void Function(Pointer<Uint8>, Int32, Pointer<Float>, Int32);
typedef LutFn = void Function(Pointer<Uint8>, int, Pointer<Float>, int);

typedef GreyscaleNative = Void Function(Pointer<Uint8>, Int32);
typedef GreyscaleFn = void Function(Pointer<Uint8>, int);

// lens_sim.cpp
typedef VignetteNative = Void Function(Pointer<Uint8>, Int32, Int32, Float);
typedef VignetteFn = void Function(Pointer<Uint8>, int, int, double);

typedef CaNative = Void Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Int32, Float);
typedef CaFn = void Function(Pointer<Uint8>, Pointer<Uint8>, int, int, double);

typedef DistortNative = Void Function(Pointer<Uint8>, Pointer<Uint8>, Int32, Int32, Float);
typedef DistortFn = void Function(Pointer<Uint8>, Pointer<Uint8>, int, int, double);

// bokeh_kernel.cpp
typedef BokehNative = Void Function(
    Pointer<Uint8>, Pointer<Uint8>, Pointer<Float>, Int32, Int32, Int32);
typedef BokehFn = void Function(
    Pointer<Uint8>, Pointer<Uint8>, Pointer<Float>, int, int, int);

// ── Singleton bridge ─────────────────────────────────────────────────────────

class NativeBridge {
  NativeBridge._() {
    _load();
  }

  static final NativeBridge instance = NativeBridge._();

  bool _loaded = false;
  bool get isLoaded => _loaded;

  late final WbFn applyWhiteBalance;
  late final ExposureFn applyExposure;
  late final ToneCurveFn applyToneCurve;
  late final KelvinFn kelvinToGains;
  late final LutFn apply3dLut;
  late final GreyscaleFn toGreyscale;
  late final VignetteFn applyVignette;
  late final CaFn applyCa;
  late final DistortFn applyDistortion;
  late final BokehFn applyBokehBlur;

  void _load() {
    try {
      final DynamicLibrary lib;
      if (Platform.isAndroid) {
        lib = DynamicLibrary.open('libicamera_native.so');
      } else if (Platform.isIOS) {
        // iOS: C++ is compiled into the app binary via NativeProcessor.podspec
        lib = DynamicLibrary.process();
      } else {
        return; // desktop / simulator — use Dart fallback
      }

      applyWhiteBalance = lib.lookupFunction<WbNative, WbFn>('apply_white_balance');
      applyExposure     = lib.lookupFunction<ExposureNative, ExposureFn>('apply_exposure');
      applyToneCurve    = lib.lookupFunction<ToneCurveNative, ToneCurveFn>('apply_tone_curve');
      kelvinToGains     = lib.lookupFunction<KelvinNative, KelvinFn>('kelvin_to_gains');
      apply3dLut        = lib.lookupFunction<LutNative, LutFn>('apply_3d_lut');
      toGreyscale       = lib.lookupFunction<GreyscaleNative, GreyscaleFn>('to_greyscale');
      applyVignette     = lib.lookupFunction<VignetteNative, VignetteFn>('apply_vignette');
      applyCa           = lib.lookupFunction<CaNative, CaFn>('apply_chromatic_aberration');
      applyDistortion   = lib.lookupFunction<DistortNative, DistortFn>('apply_distortion');
      applyBokehBlur    = lib.lookupFunction<BokehNative, BokehFn>('apply_bokeh_blur');

      _loaded = true;
    } catch (_) {
      // Native library unavailable — Dart fallback active automatically.
      _loaded = false;
    }
  }
}
