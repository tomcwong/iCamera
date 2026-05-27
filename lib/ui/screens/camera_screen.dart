import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:native_exif/native_exif.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/theme/leica_colors.dart';
import '../../features/bokeh/segmentation_service.dart';
import '../../features/camera/camera_service.dart';
import '../../features/camera/models/capture_settings.dart';
import '../../features/color_science/color_profile.dart';
import '../../features/color_science/leica_looks.dart';
import '../../features/lens_simulation/lens_profile.dart';
import '../../features/raw_capture/dng_writer.dart';
import '../../services/image_pipeline.dart';
import '../../services/manual_camera_service.dart';
import '../widgets/shutter_button.dart';
import '../widgets/exposure_wheel.dart';
import '../widgets/wb_selector.dart';
import '../widgets/lens_selector.dart';

final captureSettingsProvider =
    StateProvider<CaptureSettings>((ref) => const CaptureSettings());

const _isoValues = [
  50, 64, 100, 125, 200, 250, 400, 500, 800, 1000, 1600, 3200, 6400
];
const _shutterValues = [
  8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1
];
const _apertureValues = [
  1.0, 1.2, 1.4, 1.8, 2.0, 2.4, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0
];

// Which panel is currently shown in the display bar.
enum _TopPanel { ssApt, apt, lens, wb, iso, looks, view, timer }

// Snap a raw live-ISO value to the nearest standard camera stop.
int _snapIso(int raw) {
  if (raw <= 0) return raw;
  const stops = [50, 64, 100, 125, 200, 250, 400, 500, 800, 1000, 1600, 3200, 6400];
  return stops.reduce((a, b) => (a - raw).abs() <= (b - raw).abs() ? a : b);
}

// ── Isolate helpers ───────────────────────────────────────────────────────────
Map<String, dynamic> _decodeAndRotate(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final angle = args['angle'] as int;
  final bakeOrient = args['bakeOrientation'] as bool? ?? false;
  var decoded = img.decodeJpg(bytes)!;
  // Bake EXIF orientation so pixel data is always upright (needed on iOS
  // because AVCapturePhotoOutput embeds orientation=6 but pixels are landscape).
  if (bakeOrient) decoded = img.bakeOrientation(decoded);
  if (angle != 0) decoded = img.copyRotate(decoded, angle: angle);
  return {
    'rgba': Uint8List.fromList(decoded.getBytes(order: img.ChannelOrder.rgba)),
    'width': decoded.width,
    'height': decoded.height,
  };
}

Uint8List _encodeRgbaToJpeg(Map<String, dynamic> args) {
  final rgba = args['rgba'] as Uint8List;
  final width = args['width'] as int;
  final height = args['height'] as int;
  final quality = args['quality'] as int? ?? 92;
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    order: img.ChannelOrder.rgba,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

// Crops decoded RGBA to the target aspect ratio (center crop).
Map<String, dynamic> _cropToAspect(Map<String, dynamic> args) {
  final rgba = args['rgba'] as Uint8List;
  final width = args['width'] as int;
  final height = args['height'] as int;
  final targetAspect = args['targetAspect'] as double;

  final currentAspect = width / height;
  int cropW = width, cropH = height, offsetX = 0, offsetY = 0;

  if (currentAspect > targetAspect) {
    cropW = (height * targetAspect).round();
    offsetX = (width - cropW) ~/ 2;
  } else if (currentAspect < targetAspect) {
    cropH = (width / targetAspect).round();
    offsetY = (height - cropH) ~/ 2;
  }

  if (cropW == width && cropH == height) {
    return {'rgba': rgba, 'width': width, 'height': height};
  }

  final src = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    order: img.ChannelOrder.rgba,
    numChannels: 4,
  );
  final cropped = img.copyCrop(src,
      x: offsetX, y: offsetY, width: cropW, height: cropH);
  return {
    'rgba':
        Uint8List.fromList(cropped.getBytes(order: img.ChannelOrder.rgba)),
    'width': cropW,
    'height': cropH,
  };
}

// Downsamples RGBA to a maximum pixel count. Returns unchanged if already small enough.
// Runs in a compute isolate to avoid blocking the UI thread.
Map<String, dynamic> _downsample(Map<String, dynamic> args) {
  final rgba = args['rgba'] as Uint8List;
  final width = args['width'] as int;
  final height = args['height'] as int;
  final maxPixels = args['maxPixels'] as int;

  if (width * height <= maxPixels) {
    return {'rgba': rgba, 'width': width, 'height': height};
  }
  final scale = math.sqrt(maxPixels / (width * height));
  final newW = (width * scale).round().clamp(1, width);
  final newH = (height * scale).round().clamp(1, height);
  final src = img.Image.fromBytes(
    width: width, height: height,
    bytes: rgba.buffer, order: img.ChannelOrder.rgba, numChannels: 4,
  );
  final scaled = img.copyResize(src, width: newW, height: newH,
      interpolation: img.Interpolation.linear);
  return {
    'rgba': Uint8List.fromList(scaled.getBytes(order: img.ChannelOrder.rgba)),
    'width': newW,
    'height': newH,
  };
}

// ── JPEG EXIF helpers ─────────────────────────────────────────────────────────
// Extract the APP1 (EXIF) segment from a JPEG byte buffer.
// Returns the raw bytes including the FF E1 marker and length prefix.
Uint8List? _extractApp1Exif(Uint8List jpeg) {
  int i = 2; // skip SOI marker FF D8
  while (i + 3 < jpeg.length) {
    if (jpeg[i] != 0xFF) break;
    final marker = jpeg[i + 1];
    final segLen = (jpeg[i + 2] << 8) | jpeg[i + 3];
    if (marker == 0xE1 &&
        i + 9 < jpeg.length &&
        jpeg[i + 4] == 0x45 && jpeg[i + 5] == 0x78 && // 'Ex'
        jpeg[i + 6] == 0x69 && jpeg[i + 7] == 0x66 && // 'if'
        jpeg[i + 8] == 0x00 && jpeg[i + 9] == 0x00) {  // \0\0
      return jpeg.sublist(i, i + 2 + segLen);
    }
    if (marker == 0xDA) break; // start-of-scan: no more headers
    i += 2 + segLen;
  }
  return null;
}

// Patch the EXIF orientation tag in an APP1 byte buffer to 1 (upright, no rotation).
// Needed after bakeOrientation bakes the rotation into pixels — the original tag
// would otherwise cause a second rotation by Photos.app.
Uint8List _patchExifOrientation1(Uint8List app1) {
  if (app1.length < 18) return app1;
  // Verify "Exif\0\0" at bytes 4–9
  if (app1[4] != 0x45 || app1[5] != 0x78 || app1[6] != 0x69 ||
      app1[7] != 0x66 || app1[8] != 0x00 || app1[9] != 0x00) { return app1; }
  final t = 10; // TIFF header offset within app1
  final le = app1[t] == 0x49; // 'II' = little-endian
  int r16(int o) => le ? (app1[o] | app1[o + 1] << 8) : (app1[o] << 8 | app1[o + 1]);
  int r32(int o) => le
      ? (app1[o] | app1[o + 1] << 8 | app1[o + 2] << 16 | app1[o + 3] << 24)
      : (app1[o] << 24 | app1[o + 1] << 16 | app1[o + 2] << 8 | app1[o + 3]);
  final ifd0 = t + r32(t + 4);
  if (ifd0 + 2 > app1.length) return app1;
  final n = r16(ifd0);
  for (int i = 0; i < n; i++) {
    final e = ifd0 + 2 + i * 12;
    if (e + 12 > app1.length) break;
    if (r16(e) == 0x0112) { // Orientation tag
      final out = Uint8List.fromList(app1);
      if (le) { out[e + 8] = 1; out[e + 9] = 0; }
      else     { out[e + 8] = 0; out[e + 9] = 1; }
      return out;
    }
  }
  return app1;
}

// Inject an APP1 segment into a JPEG, replacing any existing APP0/APP1.
Uint8List _injectApp1Exif(Uint8List jpeg, Uint8List app1) {
  final out = BytesBuilder();
  out.add(const [0xFF, 0xD8]); // SOI
  out.add(app1);               // inject EXIF right after SOI
  int i = 2;
  while (i + 1 < jpeg.length) {
    if (jpeg[i] != 0xFF) { out.add(jpeg.sublist(i)); break; }
    final marker = jpeg[i + 1];
    if (marker == 0xDA) { out.add(jpeg.sublist(i)); break; } // SOS + image data
    if (i + 3 >= jpeg.length) break;
    final segLen = (jpeg[i + 2] << 8) | jpeg[i + 3];
    // Skip APP0 (JFIF) and APP1 (old EXIF) — they are replaced by our injected one
    if (marker == 0xE0 || marker == 0xE1) { i += 2 + segLen; continue; }
    out.add(jpeg.sublist(i, i + 2 + segLen));
    i += 2 + segLen;
  }
  return out.toBytes();
}

// ── Main screen ───────────────────────────────────────────────────────────────
class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with WidgetsBindingObserver {
  bool _isCapturing = false;
  String? _lastCapturePath;
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  bool _zoomIndicatorVisible = false;
  Timer? _zoomHideTimer;

  // Tap-to-focus
  Offset? _focusIndicatorPos;
  bool _focusVisible = false;
  Timer? _focusHideTimer;
  Size _previewRenderSize = Size.zero;

  // UI state
  _TopPanel? _activeTopPanel;
  bool _showGearPanel = false;
  int _timerCountdown = 0;
  bool _showGrid = false;
  bool _showLevel = false;
  bool _mirrorFront = false;

  // Live exposure readout (AUTO mode)
  int _liveIso = 0;
  int _liveShutterDenom = 0;
  double _liveEv = 0;
  double _liveAperture = 0;
  // 2-second periodic HUD refresh in AUTO mode so values track scene changes.
  // Much gentler than the old 600 ms timer; cancelled in PRO mode.
  Timer? _liveExposureTimer;

  // GPS for EXIF
  Position? _lastGpsPosition;
  StreamSubscription<Position>? _gpsSub;

  // Available optical zoom levels (detected from hardware on iOS)
  List<double> _availableZooms = [1.0];

  // Live face detection bounding boxes (normalized 0–1, top-left origin)
  List<Map<String, double>> _detectedFaces = [];
  StreamSubscription<dynamic>? _faceSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.read(lutPreloadProvider);
    _initGps();
    _loadAvailableZooms();
    _subscribeFaceStream();
    _startAutoModeHudPoll();
  }

  Future<void> _loadAvailableZooms() async {
    final zooms = await ManualCameraService.instance.getAvailableZoomFactors();
    if (mounted) setState(() => _availableZooms = zooms);
  }

  @override
  void dispose() {
    _zoomHideTimer?.cancel();
    _focusHideTimer?.cancel();
    _liveExposureTimer?.cancel();
    _faceSub?.cancel();
    _gpsSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 2-second periodic HUD refresh, runs only in AUTO mode.
  // Gentle enough not to impact battery; stops automatically when PRO is active.
  void _startAutoModeHudPoll() {
    _liveExposureTimer?.cancel();
    _liveExposureTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) async {
      final settings = ref.read(captureSettingsProvider);
      if (settings.mode != CaptureMode.auto) return; // stop firing in PRO
      await _readAndApplyLiveExposure();
    });
  }

  // Burst of reads after tap-to-focus: camera re-meters over ~1.5 s so we
  // sample at 500 ms, 1000 ms, and 1500 ms to catch the settled value.
  void _pollAfterFocus() {
    for (final delay in [500, 1000, 1500]) {
      Future.delayed(Duration(milliseconds: delay), () async {
        final settings = ref.read(captureSettingsProvider);
        if (!mounted || settings.mode != CaptureMode.auto) return;
        await _readAndApplyLiveExposure();
      });
    }
  }

  Future<void> _readAndApplyLiveExposure() async {
    final live = await ManualCameraService.instance.getLiveExposure();
    if (live != null && mounted) {
      setState(() {
        final apt = (live['aperture'] as num?)?.toDouble() ?? 0;
        if (apt > 0) _liveAperture = apt;
        _liveIso = (live['iso'] as num?)?.toInt() ?? 0;
        _liveShutterDenom = (live['shutterDenom'] as num?)?.toInt() ?? 0;
        _liveEv = (live['ev'] as num?)?.toDouble() ?? 0;
      });
    }
  }

  void _subscribeFaceStream() {
    _faceSub = ManualCameraService.faceStream.listen((raw) {
      if (!mounted || raw == null) return;
      final list = (raw as List).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return <String, double>{
          'x': (m['x'] as num).toDouble(),
          'y': (m['y'] as num).toDouble(),
          'w': (m['w'] as num).toDouble(),
          'h': (m['h'] as num).toDouble(),
        };
      }).toList();
      setState(() => _detectedFaces = list);
    }, onError: (_) {});
  }

  Future<void> _initGps() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) { return; }
      if (!await Geolocator.isLocationServiceEnabled()) { return; }
      _lastGpsPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 50,
        ),
      ).listen((p) => _lastGpsPosition = p, onError: (_) {});
    } catch (_) {}
  }

  Future<void> _setZoom(double zoom, {bool showIndicator = false}) async {
    final applied =
        await ref.read(cameraControllerProvider.notifier).setZoomLevel(zoom);
    if (!mounted) return;
    setState(() {
      _currentZoom = applied;
      if (showIndicator) _zoomIndicatorVisible = true;
    });
    if (showIndicator) {
      _zoomHideTimer?.cancel();
      _zoomHideTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _zoomIndicatorVisible = false);
      });
    }
  }

  Future<void> _tapToFocus(Offset localPos) async {
    final ctrl = ref.read(cameraControllerProvider).value;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final settings = ref.read(captureSettingsProvider);
    final isPro = settings.mode == CaptureMode.manual;
    final size = _previewRenderSize;
    if (size == Size.zero) return;
    final nx = (localPos.dx / size.width).clamp(0.0, 1.0);
    final ny = (localPos.dy / size.height).clamp(0.0, 1.0);
    try {
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setFocusPoint(Offset(nx, ny));
      // In PRO mode keep exposure manual — only move the focus point.
      if (!isPro) {
        await ctrl.setExposureMode(ExposureMode.auto);
        await ctrl.setExposurePoint(Offset(nx, ny));
      }
    } catch (_) {}
    setState(() {
      _focusIndicatorPos = localPos;
      _focusVisible = true;
    });
    _focusHideTimer?.cancel();
    _focusHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusVisible = false);
    });
    // After the focus point moves, burst-sample exposure so the HUD shows the
    // camera's settled value (re-metering takes up to ~1.5 s after tap).
    _pollAfterFocus();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = ref.read(cameraControllerProvider).value;
    if (ctrl == null) return;
    if (state == AppLifecycleState.inactive) {
      ctrl.dispose();
    } else if (state == AppLifecycleState.resumed) {
      ref.read(cameraControllerProvider.notifier).initialize();
    }
  }

  Future<void> _capture() async {
    if (_isCapturing || _timerCountdown > 0) return;
    final settings = ref.read(captureSettingsProvider);
    if (settings.timerSeconds > 0) {
      for (int i = settings.timerSeconds; i > 0; i--) {
        if (!mounted) return;
        setState(() => _timerCountdown = i);
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      setState(() => _timerCountdown = 0);
    }
    setState(() => _isCapturing = true);

    XFile? xfile;
    Float32List? appleMatte;
    int? appleMatteW, appleMatteH;

    if (settings.mode == CaptureMode.manual && Platform.isIOS) {
      // PRO mode on iOS: apply manual exposure then use our native capture path
      // which sets isAutoVirtualDeviceFusionEnabled=false + photoQualityPrioritization=.speed
      // so iOS cannot override ISO/SS with Smart HDR or Deep Fusion.
      await ref
          .read(cameraControllerProvider.notifier)
          .applyManualSettings(settings);
      final result = await ManualCameraService.instance.captureProPhoto();
      if (result != null) {
        final dir = await getTemporaryDirectory();
        final path =
            '${dir.path}/icamera_pro_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(path).writeAsBytes(result.jpeg);
        xfile = XFile(path);
        // Apple Portrait Matte — if present, skip the slower Vision segmentation
        appleMatte = result.mask;
        appleMatteW = result.maskWidth;
        appleMatteH = result.maskHeight;
      }
    }

    if (xfile == null) {
      // AUTO mode, non-iOS PRO, or fallback when native capture fails.
      if (settings.mode == CaptureMode.manual) {
        await ref
            .read(cameraControllerProvider.notifier)
            .applyManualSettings(settings);
      }
      xfile = await ref.read(cameraControllerProvider.notifier).capture();
    }

    setState(() => _isCapturing = false);
    if (xfile == null) return;
    final rotAngle = _captureRotationDegrees();
    _processAndSave(xfile, settings, rotAngle,
        appleMatte: appleMatte, appleMatteW: appleMatteW, appleMatteH: appleMatteH);
  }

  Future<void> _processAndSave(
      XFile xfile, CaptureSettings settings, int rotAngle, {
      Float32List? appleMatte,
      int? appleMatteW,
      int? appleMatteH,
  }) async {
    try {
      if (settings.rawEnabled) {
        final path = await DngWriter.instance.save(xfile, asRaw: true);
        if (mounted) setState(() => _lastCapturePath = path);
        return;
      }

      final rawBytes = await xfile.readAsBytes();
      Map<String, dynamic>? decodeResult;
      try {
        decodeResult = await compute(_decodeAndRotate, {
          'bytes': rawBytes,
          'angle': rotAngle,
          // On iOS the capture JPEG has orientation=6 (pixels are landscape).
          // bakeOrientation rotates them to portrait so they're always upright.
          'bakeOrientation': Platform.isIOS,
        });
      } catch (_) {}

      if (decodeResult == null) {
        final path = await DngWriter.instance.save(xfile, asRaw: false);
        if (mounted) setState(() => _lastCapturePath = path);
        return;
      }

      // Crop to selected aspect ratio.
      // For a portrait source (width < height) 16:9 means 9:16 (tall crop).
      if (settings.aspectRatio == CaptureAspectRatio.aspect16_9) {
        final srcW = decodeResult['width'] as int;
        final srcH = decodeResult['height'] as int;
        final targetAspect = srcW < srcH ? 9.0 / 16.0 : 16.0 / 9.0;
        decodeResult = await compute(_cropToAspect, {
          'rgba': decodeResult['rgba'],
          'width': srcW,
          'height': srcH,
          'targetAspect': targetAspect,
        });
      }

      // Downsample to max 6 MP before the heavy processing pipeline.
      // 12 MP (max preset) → 6 MP cuts processing time ~2× with no visible quality
      // loss on any display. Runs in an isolate so the UI stays responsive.
      const maxProcessingPixels = 6 * 1024 * 1024;
      decodeResult = await compute(_downsample, {
        'rgba': decodeResult['rgba'],
        'width': decodeResult['width'],
        'height': decodeResult['height'],
        'maxPixels': maxProcessingPixels,
      });

      final rgba = decodeResult['rgba'] as Uint8List;
      final width = decodeResult['width'] as int;
      final height = decodeResult['height'] as int;

      Float32List? mask;
      if (settings.mode == CaptureMode.manual && settings.aperture < 8.0) {
        if (appleMatte != null && appleMatteW != null && appleMatteH != null) {
          // Use Apple's Portrait Effects Matte (Neural Engine, hair-strand precision).
          // Bilinearly resample it from its native resolution to the processed image size.
          mask = _resampleMask(appleMatte, appleMatteW, appleMatteH, width, height);
        } else {
          // Fallback: run Vision person segmentation post-capture.
          mask = await ref
              .read(segmentationServiceProvider)
              .segment(File(xfile.path), width, height);
        }
      }

      final processedRgba = await ref.read(imagePipelineProvider).process(
            rgba: rgba,
            width: width,
            height: height,
            settings: settings,
            segmentationMask: mask,
          );

      String path;
      if (settings.quality == CaptureQuality.heif) {
        // Encode processed pixels directly to HEIF — no intermediate JPEG step.
        final heifBytes = await ManualCameraService.instance
            .encodePixelsToHeif(processedRgba, width, height, quality: 0.9);
        if (heifBytes != null) {
          // Save locally first so GPS can be added before gallery copy.
          path = await DngWriter.instance.saveHeifLocal(heifBytes);
        } else {
          // Fallback: HEIF unavailable (Android / error), save as JPEG.
          final jpegBytes = await compute(_encodeRgbaToJpeg,
              {'rgba': processedRgba, 'width': width, 'height': height, 'quality': 85});
          final app1Raw = _extractApp1Exif(rawBytes);
          final app1 = app1Raw != null ? _patchExifOrientation1(app1Raw) : null;
          final finalJpeg = app1 != null ? _injectApp1Exif(jpegBytes, app1) : jpegBytes;
          path = await DngWriter.instance.saveJpegLocal(finalJpeg);
        }
      } else {
        final jpegQuality = settings.quality == CaptureQuality.high ? 97 : 85;
        final jpegBytes = await compute(_encodeRgbaToJpeg, {
          'rgba': processedRgba,
          'width': width,
          'height': height,
          'quality': jpegQuality,
        });
        final app1Raw = _extractApp1Exif(rawBytes);
        final app1 = app1Raw != null ? _patchExifOrientation1(app1Raw) : null;
        final finalJpeg = app1 != null ? _injectApp1Exif(jpegBytes, app1) : jpegBytes;
        // Save locally so GPS can be injected before the gallery copy is made.
        path = await DngWriter.instance.saveJpegLocal(finalJpeg);
      }
      // Inject GPS into local file, then copy to gallery so both have location.
      await _addGpsExif(path, _lastGpsPosition);
      await DngWriter.instance.copyToGallery(path);
      if (mounted) setState(() => _lastCapturePath = path);
    } catch (_) {}
  }

  // Bilinearly resample a Float32 mask from [srcW×srcH] to [dstW×dstH].
  static Float32List _resampleMask(
      Float32List src, int srcW, int srcH, int dstW, int dstH) {
    final dst = Float32List(dstW * dstH);
    final fSrcW = (srcW - 1).toDouble();
    final fSrcH = (srcH - 1).toDouble();
    for (int dy = 0; dy < dstH; dy++) {
      final fy = dy * fSrcH / (dstH - 1);
      final sy0 = fy.toInt().clamp(0, srcH - 1);
      final sy1 = (sy0 + 1).clamp(0, srcH - 1);
      final ty = fy - sy0;
      for (int dx = 0; dx < dstW; dx++) {
        final fx = dx * fSrcW / (dstW - 1);
        final sx0 = fx.toInt().clamp(0, srcW - 1);
        final sx1 = (sx0 + 1).clamp(0, srcW - 1);
        final tx = fx - sx0;
        final v = (src[sy0 * srcW + sx0] * (1 - tx) + src[sy0 * srcW + sx1] * tx) * (1 - ty)
                + (src[sy1 * srcW + sx0] * (1 - tx) + src[sy1 * srcW + sx1] * tx) * ty;
        dst[dy * dstW + dx] = v.clamp(0.0, 1.0);
      }
    }
    return dst;
  }

  // Convert decimal degrees to the "d/1 m/1 s*100/100" rational DMS string
  // that native_exif / EXIF spec expects for GPSLatitude / GPSLongitude.
  static String _decimalToDmsRational(double decimal) {
    final abs = decimal.abs();
    final deg = abs.toInt();
    final minF = (abs - deg) * 60;
    final min = minF.toInt();
    final secX100 = ((minF - min) * 6000).round();
    return '$deg/1 $min/1 $secX100/100';
  }

  Future<void> _addGpsExif(String path, Position? gps) async {
    if (gps == null) return;
    if (Platform.isIOS) {
      // native_exif GPS writing silently fails on iOS — use native Swift instead.
      await ManualCameraService.instance.writeGpsToPhoto(
        path: path,
        lat: gps.latitude,
        lon: gps.longitude,
        alt: gps.altitude,
      );
      return;
    }
    try {
      final attrs = <String, String>{
        'GPSLatitude': _decimalToDmsRational(gps.latitude),
        'GPSLatitudeRef': gps.latitude >= 0 ? 'N' : 'S',
        'GPSLongitude': _decimalToDmsRational(gps.longitude),
        'GPSLongitudeRef': gps.longitude >= 0 ? 'E' : 'W',
      };
      if (gps.altitude != 0) {
        attrs['GPSAltitude'] = '${(gps.altitude.abs() * 100).round()}/100';
        attrs['GPSAltitudeRef'] = gps.altitude >= 0 ? '0' : '1';
      }
      final exif = await Exif.fromPath(path);
      await exif.writeAttributes(attrs);
      await exif.close();
    } catch (_) {}
  }

  int _captureRotationDegrees() {
    if (!Platform.isAndroid) return 0;
    final ctrl = ref.read(cameraControllerProvider).value;
    if (ctrl?.description.sensorOrientation == 0) return 180;
    return 0;
  }

  void _updateSettings(CaptureSettings Function(CaptureSettings) update) {
    final prev = ref.read(captureSettingsProvider);
    ref.read(captureSettingsProvider.notifier).update(update);
    final next = ref.read(captureSettingsProvider);
    if (prev.selectedLens != next.selectedLens) {
      _setZoom(next.selectedLens.defaultZoom);
    }
    // Apply manual exposure immediately when ISO or SS changes in PRO mode so
    // the sensor updates before capture and the live HUD reflects real values.
    if (next.mode == CaptureMode.manual &&
        (prev.iso != next.iso ||
            prev.shutterSpeedDenominator != next.shutterSpeedDenominator)) {
      ref.read(cameraControllerProvider.notifier).applyManualSettings(next);
    }
    // Keep the periodic HUD poll running only in AUTO mode.
    if (prev.mode != next.mode) {
      if (next.mode == CaptureMode.auto) {
        _startAutoModeHudPoll(); // restart 2-second cycle when entering AUTO
      } else {
        _liveExposureTimer?.cancel(); // no polling needed in PRO
      }
    }
  }

  void _toggleTopPanel(_TopPanel panel) {
    setState(() {
      _activeTopPanel = _activeTopPanel == panel ? null : panel;
      if (_activeTopPanel != null) _showGearPanel = false;
    });
  }

  void _openGallery() {
    if (_lastCapturePath != null && mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _PhotoViewPage(path: _lastCapturePath!),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraControllerProvider);
    final settings = ref.watch(captureSettingsProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    ref.listen<CaptureSettings>(captureSettingsProvider, (prev, next) {
      // Only re-apply manual exposure when something that actually affects the
      // sensor changes (mode, ISO, shutter speed). Aperture/WB/lens/look changes
      // don't need a setManualExposure round-trip and were causing redundant
      // lockForConfiguration calls that could hang the capture flow.
      if (prev?.mode != next.mode ||
          prev?.iso != next.iso ||
          prev?.shutterSpeedDenominator != next.shutterSpeedDenominator) {
        ref.read(cameraControllerProvider.notifier).applyManualSettings(next);
      }
      if (prev?.quality != next.quality) {
        ref.read(cameraControllerProvider.notifier).setQuality(next.quality);
      }
    });

    final activeController = cameraState.valueOrNull;

    final isFrontCamera = activeController?.description.lensDirection ==
        CameraLensDirection.front;
    Widget previewWidget = cameraState.when(
      data: (ctrl) => ctrl != null && ctrl.value.isInitialized
          ? _CameraPreview(
              controller: ctrl,
              settings: settings,
              mirrorHorizontally: _mirrorFront && isFrontCamera,
            )
          : const _LoadingView(),
      loading: () => const _LoadingView(),
      error: (e, _) => _ErrorView(error: e.toString()),
    );

    final bottomBarWidget = _BottomBar(
      settings: settings,
      isCapturing: _isCapturing,
      lastCapturePath: _lastCapturePath,
      onCapture: _capture,
      onSettingsChanged: _updateSettings,
      onSwitchCamera: () =>
          ref.read(cameraControllerProvider.notifier).switchCamera(),
      onOpenGallery: _openGallery,
      onGearTap: () => setState(() {
        _showGearPanel = !_showGearPanel;
        if (_showGearPanel) _activeTopPanel = null;
      }),
    );

    final displayBarWidget = _activeTopPanel != null
        ? _DisplayBar(
            panel: _activeTopPanel!,
            settings: settings,
            onSettingsChanged: _updateSettings,
            onWbChanged: (k) =>
                _updateSettings((s) => s.copyWith(whiteBalanceKelvin: k)),
            showGrid: _showGrid,
            onGridToggle: () => setState(() => _showGrid = !_showGrid),
            showLevel: _showLevel,
            onLevelToggle: () => setState(() => _showLevel = !_showLevel),
            showMirror: _mirrorFront,
            onMirrorToggle: () => setState(() => _mirrorFront = !_mirrorFront),
          )
        : const SizedBox.shrink();

    final topHudWidget = _TopHud(
      settings: settings,
      activePanel: _activeTopPanel,
      onPanelTap: _toggleTopPanel,
      liveIso: _liveIso,
      liveShutterDenom: _liveShutterDenom,
      liveEv: _liveEv,
      liveAperture: _liveAperture,
    );

    final gearOverlay = _showGearPanel
        ? Positioned.fill(
            child: _GearPanel(
              settings: settings,
              onDismiss: () => setState(() => _showGearPanel = false),
              onSettingsChanged: _updateSettings,
              onPanelActivate: (panel) => setState(() {
                _showGearPanel = false;
                _activeTopPanel = panel;
              }),
            ),
          )
        : null;

    final previewStack = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (_) => _baseZoom = _currentZoom,
      onScaleUpdate: (d) {
        if (d.pointerCount >= 2) {
          _setZoom((_baseZoom * d.scale).clamp(1.0, 10.0),
              showIndicator: true);
        }
      },
      onTapUp: (d) => _tapToFocus(d.localPosition),
      child: LayoutBuilder(
        builder: (_, cns) {
          _previewRenderSize = cns.biggest;
          return Stack(
            fit: StackFit.expand,
            children: [
              previewWidget,
              if (settings.aspectRatio == CaptureAspectRatio.aspect16_9)
                _AspectCropOverlay(isLandscape: isLandscape, controller: activeController),
              if (_showGrid) const _GridOverlay(),
              if (_showLevel) const _LevelIndicator(),
              if (_timerCountdown > 0)
                Center(
                  child: Text(
                    '$_timerCountdown',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 96,
                      fontWeight: FontWeight.w200,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 24)],
                    ),
                  ),
                ),
              if (_zoomIndicatorVisible)
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_currentZoom.toStringAsFixed(1)}×',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_focusVisible && _focusIndicatorPos != null)
                Positioned(
                  left: _focusIndicatorPos!.dx - 36,
                  top: _focusIndicatorPos!.dy - 36,
                  child: IgnorePointer(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: const Color(0xFFFFD700), width: 1.5),
                      ),
                    ),
                  ),
                ),
              // Note: no live DoF circle overlay — bokeh is applied at capture time
              // using Vision segmentation / Portrait Matte, not in the viewfinder.
              // Live face detection — yellow squares around detected faces
              if (_detectedFaces.isNotEmpty)
                IgnorePointer(
                  child: _FaceBoxOverlay(
                    faces: _detectedFaces,
                    previewSize: cns.biggest,
                  ),
                ),
            ],
          );
        },
      ),
    );

    if (isLandscape) {
      // ── Landscape: left rail (HUD) + full-height preview + right rail (controls)
      // This gives a much larger preview than the old centered AspectRatio approach.
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left rail — SS / APT / LEICA / WB / ISO
                  _LandscapeLeftRail(
                    settings: settings,
                    activePanel: _activeTopPanel,
                    onPanelTap: _toggleTopPanel,
                    liveIso: _liveIso,
                    liveShutterDenom: _liveShutterDenom,
                    liveAperture: _liveAperture,
                  ),
                  // Centre — preview (previewStack already handles gestures,
                  // focus indicator, zoom indicator, grid, and crop overlay)
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        previewStack,
                        // Display bar overlaid at bottom when a panel is open
                        if (_activeTopPanel != null)
                          Positioned(
                            bottom: 0, left: 0, right: 0,
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.88),
                              child: displayBarWidget,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Right rail — thumbnail / mode / shutter / flip / gear
                  _LandscapeRightRail(
                    settings: settings,
                    isCapturing: _isCapturing,
                    lastCapturePath: _lastCapturePath,
                    onCapture: _capture,
                    onSettingsChanged: _updateSettings,
                    onSwitchCamera: () =>
                        ref.read(cameraControllerProvider.notifier).switchCamera(),
                    onOpenGallery: _openGallery,
                    onGearTap: () => setState(() {
                      _showGearPanel = !_showGearPanel;
                      if (_showGearPanel) _activeTopPanel = null;
                    }),
                  ),
                ],
              ),
              // Gear overlay spans the whole screen
              if (_showGearPanel)
                Positioned.fill(
                  child: _GearPanel(
                    settings: settings,
                    onDismiss: () => setState(() => _showGearPanel = false),
                    onSettingsChanged: _updateSettings,
                    onPanelActivate: (panel) => setState(() {
                      _showGearPanel = false;
                      _activeTopPanel = panel;
                    }),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // ── Portrait: Column layout, preview fills all space between bars ─
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              SafeArea(
                bottom: false,
                child: topHudWidget,
              ),
              // Expanded wraps a LayoutBuilder so we can overlay the 4:3 frame
              // indicator at the correct position regardless of internal stack layout.
              Expanded(
                child: LayoutBuilder(builder: (_, cns) {
                  final W = cns.maxWidth;
                  final H = cns.maxHeight;
                  final bar = ((H - W * 4 / 3) / 2).clamp(0.0, H);
                  const dim = Color(0xDD000000); // 87% — clearly visible
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      previewStack,
                      if (bar >= 4) ...[
                        // Top dim strip
                        Positioned(top: 0, left: 0, right: 0, height: bar,
                            child: Container(color: dim)),
                        // Bottom dim strip
                        Positioned(bottom: 0, left: 0, right: 0, height: bar,
                            child: Container(color: dim)),
                        // Bright frame boundary lines at the 4:3 edge
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _FrameLinePainter(topBar: bar),
                            ),
                          ),
                        ),
                      ],
                      // Zoom buttons overlaid at the bottom of the preview area
                      Positioned(
                        bottom: math.max(bar, 0.0) + 10,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: _ZoomButtons(
                            availableZooms: _availableZooms,
                            currentZoom: _currentZoom,
                            onZoom: _setZoom,
                          ),
                        ),
                      ),
                    ],
                  );
                }),
              ),
              SizedBox(height: 90, child: displayBarWidget),
              bottomBarWidget,
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
          ?gearOverlay,
        ],
      ),
    );
  }
}

// ── Bokeh preview overlay (APT mode live DoF simulation) ─────────────────────
// Blurs everything outside a circle centred on the tap-to-focus point.

// ── Camera Preview ────────────────────────────────────────────────────────────
class _CameraPreview extends StatelessWidget {
  const _CameraPreview({
    required this.controller,
    required this.settings,
    this.mirrorHorizontally = false,
  });

  final CameraController controller;
  final CaptureSettings settings;
  final bool mirrorHorizontally;

  static List<double> _wbMatrix(int kelvin) {
    final t = (kelvin - 5500) / 4500.0;
    final r = (1.0 + t * 0.50).clamp(0.5, 1.5);
    final b = (1.0 - t * 0.58).clamp(0.5, 1.8);
    return [r, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, b, 0, 0, 0, 0, 0, 1, 0];
  }

  static int _quarterTurns(CameraDescription camera) {
    if (!Platform.isAndroid) return 0;
    return camera.sensorOrientation == 0 ? 2 : 0;
  }

  @override
  Widget build(BuildContext context) {
    final bool deviceLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    // On iOS, AVFoundation handles orientation internally — just wrap CameraPreview
    // directly so it fills the AspectRatio box without FittedBox confusion.
    // On Android, manually rotate/scale based on sensor orientation.
    Widget cameraChild;
    if (Platform.isIOS) {
      cameraChild = CameraPreview(controller);
    } else {
      final previewSize = controller.value.previewSize!;
      final int turns = _quarterTurns(controller.description);
      final int sensor = controller.description.sensorOrientation;
      final bool pluginRotates = !deviceLandscape &&
          turns == 0 &&
          (sensor == 90 || sensor == 270);
      final bool swapDims = (turns % 2 == 1) || pluginRotates;
      final double displayW =
          swapDims ? previewSize.height : previewSize.width;
      final double displayH =
          swapDims ? previewSize.width : previewSize.height;
      cameraChild = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: displayW,
          height: displayH,
          child: RotatedBox(
            quarterTurns: turns,
            child: CameraPreview(controller),
          ),
        ),
      );
    }

    // Always apply WB tint; additionally apply look preview matrix when Leica is ON.
    Widget graded = ColorFiltered(
      colorFilter: ColorFilter.matrix(
          _CameraPreview._wbMatrix(settings.whiteBalanceKelvin)),
      child: cameraChild,
    );
    if (settings.leicaLookEnabled) {
      graded = ColorFiltered(
        colorFilter:
            ColorFilter.matrix(settings.selectedLook.previewMatrix),
        child: graded,
      );
    }

    Widget preview = ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          graded,
          Positioned(
            top: 8,
            right: 8,
            child: _LookBadge(
              look: settings.selectedLook,
              leicaLookEnabled: settings.leicaLookEnabled,
            ),
          ),
        ],
      ),
    );

    if (mirrorHorizontally) {
      preview = Transform.scale(scaleX: -1, child: preview);
    }
    return preview;
  }
}

// ── Aspect ratio crop overlay ─────────────────────────────────────────────────
// Dims the area outside the selected crop (shown when 16:9 is active).
class _AspectCropOverlay extends StatelessWidget {
  const _AspectCropOverlay({required this.isLandscape, this.controller});
  final bool isLandscape;
  final CameraController? controller;

  // Compute left/right bar width as a fraction of preview box width.
  //
  // On iOS with ResolutionPreset.max the live preview stream is typically 9:16
  // (a centre crop of the 4:3 sensor), even though the still capture is full 4:3.
  // The 9:16 final crop of the 4:3 capture has exactly the same horizontal extent
  // as the 9:16 preview stream, so the bars should be 0. On Android (4:3 stream)
  // the bars fall back to the classic W/8 calculation.
  double _portraitBarFraction() {
    final previewSize = controller?.value.previewSize;
    if (previewSize == null || previewSize.width == 0 || previewSize.height == 0) {
      // No controller yet — assume preview = full 4:3 capture.
      return 0.125;
    }
    // previewSize may be in landscape (width > height) or portrait orientation.
    // Normalise to portrait aspect = short / long.
    final pw = previewSize.width, ph = previewSize.height;
    final streamPortraitAspect = pw > ph ? ph / pw : pw / ph;
    const boxPortraitAspect = 3.0 / 4.0;   // preview box is always 3:4
    // streamFraction: fraction of the 4:3 capture width visible in the preview.
    final streamFraction = (streamPortraitAspect / boxPortraitAspect).clamp(0.0, 1.0);
    // barFraction = 0.5 * (streamFraction - cropFraction)
    //   cropFraction = (9/16)/(3/4) = 3/4 = 0.75
    //   When stream is 9:16 → streamFraction=0.75 → barFraction=0  (no bars)
    //   When stream is 3:4  → streamFraction=1.0  → barFraction=0.125 (W/8)
    return (streamFraction / 2.0 - 3.0 / 8.0).clamp(0.0, 0.5);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final W = constraints.maxWidth;
      final H = constraints.maxHeight;
      const dim = Color(0xAA000000);

      // Landscape preview is 4:3; 16:9 crop removes top/bottom.
      // Portrait preview is 3:4; 9:16 crop removes left/right (adjusted for stream AR).
      double left = 0, top = 0, right = 0, bottom = 0;
      if (isLandscape) {
        final cropH = W * 9 / 16;
        final bar = ((H - cropH) / 2).clamp(0.0, H);
        top = bar;
        bottom = bar;
      } else {
        final bar = (W * _portraitBarFraction()).clamp(0.0, W);
        left = bar;
        right = bar;
      }

      return Stack(children: [
        if (left > 0)
          Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: left,
              child: Container(color: dim)),
        if (right > 0)
          Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: right,
              child: Container(color: dim)),
        if (top > 0)
          Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: top,
              child: Container(color: dim)),
        if (bottom > 0)
          Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: bottom,
              child: Container(color: dim)),
        // Corner bracket lines marking the active crop area
        CustomPaint(
          size: Size(W, H),
          painter:
              _CropBracketPainter(left: left, top: top, right: right, bottom: bottom),
        ),
      ]);
    });
  }
}

class _CropBracketPainter extends CustomPainter {
  const _CropBracketPainter(
      {required this.left,
      required this.top,
      required this.right,
      required this.bottom});
  final double left, top, right, bottom;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const L = 16.0; // bracket arm length

    final x0 = left, y0 = top;
    final x1 = size.width - right, y1 = size.height - bottom;

    // Four corners
    for (final corner in [
      [x0, y0, 1.0, 1.0],
      [x1, y0, -1.0, 1.0],
      [x0, y1, 1.0, -1.0],
      [x1, y1, -1.0, -1.0],
    ]) {
      final cx = corner[0], cy = corner[1];
      final dx = corner[2], dy = corner[3];
      canvas.drawLine(
          Offset(cx, cy), Offset(cx + dx * L, cy), paint);
      canvas.drawLine(
          Offset(cx, cy), Offset(cx, cy + dy * L), paint);
    }
  }

  @override
  bool shouldRepaint(_CropBracketPainter old) =>
      old.left != left ||
      old.top != top ||
      old.right != right ||
      old.bottom != bottom;
}

// ── Top HUD ───────────────────────────────────────────────────────────────────
class _TopHud extends StatelessWidget {
  const _TopHud({
    required this.settings,
    required this.activePanel,
    required this.onPanelTap,
    this.liveIso = 0,
    this.liveShutterDenom = 0,
    this.liveEv = 0,
    this.liveAperture = 0,
  });

  final CaptureSettings settings;
  final _TopPanel? activePanel;
  final void Function(_TopPanel) onPanelTap;
  final int liveIso;
  final int liveShutterDenom;
  final double liveEv;
  final double liveAperture;

  @override
  Widget build(BuildContext context) {
    final isAuto = settings.mode == CaptureMode.auto;
    final ssStr = (isAuto && liveShutterDenom > 0)
        ? '1/$liveShutterDenom'
        : settings.shutterSpeedLabel;
    final isoRaw = (isAuto && liveIso > 0) ? liveIso : settings.iso;
    final isoStr = '${_snapIso(isoRaw)}';
    // PRO: show selected depth/aperture value. AUTO: show hardware f-stop.
    final aptStr = !isAuto
        ? settings.apertureLabel
        : (liveAperture > 0 ? 'f/${liveAperture.toStringAsFixed(1)}' : '--');

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.only(top: 4, left: 12, right: 12, bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // App title
          const Text(
            'i C a m e r a',
            style: TextStyle(
              color: LeicaColors.textPrimary,
              fontSize: 9,
              fontWeight: FontWeight.w300,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 4),
          // Control row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // SS
              _HudTap(
                active: activePanel == _TopPanel.ssApt,
                onTap: () => onPanelTap(_TopPanel.ssApt),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text('SS',
                        style: TextStyle(
                            color: LeicaColors.textDisabled,
                            fontSize: 7,
                            letterSpacing: 1.5)),
                    const SizedBox(height: 2),
                    Text(ssStr,
                        style: const TextStyle(
                            color: LeicaColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              // DEPTH
              _HudTap(
                active: activePanel == _TopPanel.apt,
                onTap: () => onPanelTap(_TopPanel.apt),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text('DEPTH',
                        style: TextStyle(
                            color: LeicaColors.textDisabled,
                            fontSize: 7,
                            letterSpacing: 1.5)),
                    const SizedBox(height: 2),
                    Text(aptStr,
                        style: const TextStyle(
                            color: LeicaColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              // LEICA — opens look-selector panel; red when look is enabled
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onPanelTap(_TopPanel.looks);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (settings.leicaLookEnabled ||
                            activePanel == _TopPanel.looks)
                        ? LeicaColors.red.withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: (settings.leicaLookEnabled ||
                              activePanel == _TopPanel.looks)
                          ? LeicaColors.red.withValues(alpha: 0.55)
                          : Colors.white30,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    'LEICA',
                    style: TextStyle(
                      color: (settings.leicaLookEnabled ||
                              activePanel == _TopPanel.looks)
                          ? LeicaColors.red
                          : Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
              // WB
              _HudTap(
                active: activePanel == _TopPanel.wb,
                onTap: () => onPanelTap(_TopPanel.wb),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('WB',
                        style: TextStyle(
                            color: LeicaColors.textDisabled,
                            fontSize: 7,
                            letterSpacing: 1.5)),
                    const SizedBox(height: 2),
                    Text(settings.wbLabel,
                        style: const TextStyle(
                            color: LeicaColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    Text(
                      CaptureSettings.wbLabels[CaptureSettings.wbPresets
                          .indexOf(settings.whiteBalanceKelvin)
                          .clamp(0, CaptureSettings.wbLabels.length - 1)],
                      style: const TextStyle(
                          color: Colors.white, fontSize: 7, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
              // ISO
              _HudTap(
                active: activePanel == _TopPanel.iso,
                onTap: () => onPanelTap(_TopPanel.iso),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('ISO',
                        style: TextStyle(
                            color: LeicaColors.textDisabled,
                            fontSize: 7,
                            letterSpacing: 1.5)),
                    const SizedBox(height: 2),
                    Text(isoStr,
                        style: const TextStyle(
                            color: LeicaColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Tappable HUD column — highlights red when its panel is open.
class _HudTap extends StatelessWidget {
  const _HudTap(
      {required this.child, required this.active, required this.onTap});
  final Widget child;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? LeicaColors.red.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: active
              ? Border.all(
                  color: LeicaColors.red.withValues(alpha: 0.55), width: 1)
              : null,
        ),
        child: child,
      ),
    );
  }
}

// ── Display Bar ───────────────────────────────────────────────────────────────
// Contextual selector shown below the preview when a top-bar item is tapped.
class _DisplayBar extends StatelessWidget {
  const _DisplayBar({
    required this.panel,
    required this.settings,
    required this.onSettingsChanged,
    required this.onWbChanged,
    required this.showGrid,
    required this.onGridToggle,
    required this.showLevel,
    required this.onLevelToggle,
    required this.showMirror,
    required this.onMirrorToggle,
  });

  final _TopPanel panel;
  final CaptureSettings settings;
  final void Function(CaptureSettings Function(CaptureSettings)) onSettingsChanged;
  final ValueChanged<int> onWbChanged;
  final bool showGrid;
  final VoidCallback onGridToggle;
  final bool showLevel;
  final VoidCallback onLevelToggle;
  final bool showMirror;
  final VoidCallback onMirrorToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: switch (panel) {
        _TopPanel.wb => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: WbSelector(
              selectedKelvin: settings.whiteBalanceKelvin,
              onSelected: onWbChanged,
            ),
          ),
        _TopPanel.lens => Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: LensSelector(
              selected: settings.selectedLens,
              onSelected: (lens) => onSettingsChanged((s) => s.copyWith(
                    selectedLens: lens,
                    aperture: lens.maxAperture,
                  )),
            ),
          ),
        _TopPanel.ssApt => _SsAptPanel(
            settings: settings,
            onSettingsChanged: onSettingsChanged,
          ),
        _TopPanel.apt => settings.mode == CaptureMode.auto
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: Text(
                    'Depth effect — switch to PRO mode to control',
                    style: TextStyle(
                        color: LeicaColors.textSecondary,
                        fontSize: 10,
                        letterSpacing: 0.5),
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ExposureWheel(
                  values: _apertureValues
                      .map((v) => 'f/${v.toStringAsFixed(1)}')
                      .toList(),
                  selectedIndex: _apertureValues
                      .indexWhere((v) => (v - settings.aperture).abs() < 0.05)
                      .clamp(0, _apertureValues.length - 1),
                  onChanged: (i) => onSettingsChanged(
                      (s) => s.copyWith(aperture: _apertureValues[i])),
                  label: 'DEPTH',
                ),
              ),
        _TopPanel.iso => _IsoPanel(
            settings: settings,
            onSettingsChanged: onSettingsChanged,
          ),
        _TopPanel.looks => _LeicaLookPanel(
            settings: settings,
            onSettingsChanged: onSettingsChanged,
          ),
        _TopPanel.view => _ViewPanel(
            showGrid: showGrid,
            onGridToggle: onGridToggle,
            showLevel: showLevel,
            onLevelToggle: onLevelToggle,
            showMirror: showMirror,
            onMirrorToggle: onMirrorToggle,
          ),
        _TopPanel.timer => _TimerPanel(
            settings: settings,
            onSettingsChanged: onSettingsChanged,
          ),
      },
    );
  }
}

// ── Leica Look panel ─────────────────────────────────────────────────────────
// Shows "LEICA LOOK" title + OFF chip + look chips.
// Selecting a look enables Leica Look; selecting OFF disables it.
class _LeicaLookPanel extends StatelessWidget {
  const _LeicaLookPanel(
      {required this.settings, required this.onSettingsChanged});
  final CaptureSettings settings;
  final void Function(CaptureSettings Function(CaptureSettings))
      onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'LEICA LOOK',
          style: TextStyle(
            color: LeicaColors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              // OFF chip
              _LookChip(
                label: 'OFF',
                isSelected: !settings.leicaLookEnabled,
                color: Colors.white54,
                onTap: () => onSettingsChanged(
                    (s) => s.copyWith(leicaLookEnabled: false)),
              ),
              const SizedBox(width: 8),
              // One chip per look
              ...LeicaLook.values.map((look) {
                final isSelected =
                    settings.leicaLookEnabled && settings.selectedLook == look;
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _LookChip(
                    label: look.displayName.toUpperCase(),
                    isSelected: isSelected,
                    color: look.accentColor,
                    onTap: () => onSettingsChanged((s) => s.copyWith(
                          selectedLook: look,
                          leicaLookEnabled: true,
                        )),
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }
}

class _LookChip extends StatelessWidget {
  const _LookChip({
    required this.label,
    required this.isSelected,
    required this.color,
    required this.onTap,
  });
  final String label;
  final bool isSelected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isSelected ? color : LeicaColors.midGray,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? color : LeicaColors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}

class _SsAptPanel extends StatelessWidget {
  const _SsAptPanel(
      {required this.settings, required this.onSettingsChanged});
  final CaptureSettings settings;
  final void Function(CaptureSettings Function(CaptureSettings))
      onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    if (settings.mode == CaptureMode.auto) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Text(
            'AUTO — shutter speed controlled automatically',
            style: TextStyle(
                color: LeicaColors.textSecondary,
                fontSize: 10,
                letterSpacing: 0.5),
          ),
        ),
      );
    }
    // PRO mode — shutter wheel
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ExposureWheel(
        values: _shutterValues.map((v) => '1/$v').toList(),
        selectedIndex: _shutterValues
            .indexOf(settings.shutterSpeedDenominator)
            .clamp(0, _shutterValues.length - 1),
        onChanged: (i) => onSettingsChanged(
            (s) => s.copyWith(shutterSpeedDenominator: _shutterValues[i])),
        label: 'SHUTTER',
      ),
    );
  }
}

class _IsoPanel extends StatelessWidget {
  const _IsoPanel(
      {required this.settings, required this.onSettingsChanged});
  final CaptureSettings settings;
  final void Function(CaptureSettings Function(CaptureSettings))
      onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    if (settings.mode == CaptureMode.auto) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Text(
            'AUTO — ISO controlled automatically',
            style: TextStyle(
                color: LeicaColors.textSecondary,
                fontSize: 10,
                letterSpacing: 0.5),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ExposureWheel(
        values: _isoValues.map((v) => v.toString()).toList(),
        selectedIndex: _isoValues
            .indexOf(settings.iso)
            .clamp(0, _isoValues.length - 1),
        onChanged: (i) =>
            onSettingsChanged((s) => s.copyWith(iso: _isoValues[i])),
        label: 'ISO',
      ),
    );
  }
}

// ── View panel ────────────────────────────────────────────────────────────────
class _ViewPanel extends StatelessWidget {
  const _ViewPanel({
    required this.showGrid,
    required this.onGridToggle,
    required this.showLevel,
    required this.onLevelToggle,
    required this.showMirror,
    required this.onMirrorToggle,
  });
  final bool showGrid;
  final VoidCallback onGridToggle;
  final bool showLevel;
  final VoidCallback onLevelToggle;
  final bool showMirror;
  final VoidCallback onMirrorToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ViewChip(
            icon: Icons.grid_on_outlined,
            label: 'GRID',
            enabled: showGrid,
            soon: false,
            onTap: onGridToggle,
          ),
          _ViewChip(
            icon: Icons.straighten_outlined,
            label: 'LEVEL',
            enabled: showLevel,
            soon: false,
            onTap: onLevelToggle,
          ),
          _ViewChip(
            icon: Icons.flip_outlined,
            label: 'MIRROR',
            enabled: showMirror,
            soon: false,
            onTap: onMirrorToggle,
          ),
        ],
      ),
    );
  }
}

class _ViewChip extends StatelessWidget {
  const _ViewChip({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.soon,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final bool soon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: enabled
                  ? LeicaColors.red.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: enabled ? LeicaColors.red : Colors.white24, width: 1),
            ),
            child: Icon(icon,
                color: enabled ? LeicaColors.red : Colors.white54, size: 20),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: enabled ? LeicaColors.red : Colors.white38,
                  fontSize: 8,
                  letterSpacing: 1)),
          if (soon)
            const Text('SOON',
                style: TextStyle(
                    color: Colors.white24, fontSize: 7, letterSpacing: 0.5))
          else
            Text(
              enabled ? 'ON' : 'OFF',
              style: TextStyle(
                  color: enabled ? LeicaColors.red : Colors.white38,
                  fontSize: 7,
                  letterSpacing: 0.5),
            ),
        ],
      ),
    );
  }
}

// ── Timer panel ───────────────────────────────────────────────────────────────
class _TimerPanel extends StatelessWidget {
  const _TimerPanel(
      {required this.settings, required this.onSettingsChanged});
  final CaptureSettings settings;
  final void Function(CaptureSettings Function(CaptureSettings))
      onSettingsChanged;

  @override
  Widget build(BuildContext context) {
    const options = [0, 3, 5, 10];
    final selected = settings.timerSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: options.map((sec) {
          final isSelected = sec == selected;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onSettingsChanged((s) => s.copyWith(timerSeconds: sec));
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? LeicaColors.red.withValues(alpha: 0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isSelected ? LeicaColors.red : LeicaColors.midGray,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Text(
                sec == 0 ? 'OFF' : '${sec}s',
                style: TextStyle(
                  color: isSelected
                      ? LeicaColors.red
                      : LeicaColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Bottom Bar ────────────────────────────────────────────────────────────────
// thumbnail | AUTO·PRO | shutter | FLIP | GEAR
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.settings,
    required this.isCapturing,
    required this.lastCapturePath,
    required this.onCapture,
    required this.onSettingsChanged,
    required this.onSwitchCamera,
    required this.onOpenGallery,
    required this.onGearTap,
  });

  final CaptureSettings settings;
  final bool isCapturing;
  final String? lastCapturePath;
  final VoidCallback onCapture;
  final void Function(CaptureSettings Function(CaptureSettings)) onSettingsChanged;
  final VoidCallback onSwitchCamera;
  final VoidCallback onOpenGallery;
  final VoidCallback onGearTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Thumbnail
          _ThumbnailPreview(path: lastCapturePath, onTap: onOpenGallery),

          // AUTO / PRO mode chips
          _ModePair(
            settings: settings,
            onModeChanged: (mode) =>
                onSettingsChanged((s) => s.copyWith(mode: mode)),
          ),

          // Shutter
          ShutterButton(onPressed: onCapture, isCapturing: isCapturing),

          // Flip camera
          _BottomIconBtn(
            icon: Icons.flip_camera_ios,
            onTap: onSwitchCamera,
          ),

          // Gear
          _BottomIconBtn(
            icon: Icons.settings,
            onTap: onGearTap,
          ),
        ],
      ),
    );
  }
}

class _ModePair extends StatelessWidget {
  const _ModePair(
      {required this.settings, required this.onModeChanged});
  final CaptureSettings settings;
  final ValueChanged<CaptureMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _MiniModeChip(
            label: 'AUTO',
            selected: settings.mode == CaptureMode.auto,
            onTap: () {
              HapticFeedback.selectionClick();
              onModeChanged(CaptureMode.auto);
            },
          ),
          _MiniModeChip(
            label: 'PRO',
            selected: settings.mode == CaptureMode.manual,
            onTap: () {
              HapticFeedback.selectionClick();
              onModeChanged(CaptureMode.manual);
            },
          ),
        ],
      ),
    );
  }
}

class _MiniModeChip extends StatelessWidget {
  const _MiniModeChip(
      {required this.label,
      required this.selected,
      required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? LeicaColors.red : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected ? LeicaColors.red : LeicaColors.lightGray,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : LeicaColors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

class _BottomIconBtn extends StatelessWidget {
  const _BottomIconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        child: Icon(icon, color: LeicaColors.textSecondary, size: 24),
      ),
    );
  }
}

// ── Landscape rails ───────────────────────────────────────────────────────────
// Left rail: vertical column of SS / APT / LEICA / WB / ISO buttons.
class _LandscapeLeftRail extends StatelessWidget {
  const _LandscapeLeftRail({
    required this.settings,
    required this.activePanel,
    required this.onPanelTap,
    this.liveIso = 0,
    this.liveShutterDenom = 0,
    this.liveAperture = 0,
  });

  final CaptureSettings settings;
  final _TopPanel? activePanel;
  final void Function(_TopPanel) onPanelTap;
  final int liveIso;
  final int liveShutterDenom;
  final double liveAperture;

  @override
  Widget build(BuildContext context) {
    final isAuto = settings.mode == CaptureMode.auto;
    final ssStr = (isAuto && liveShutterDenom > 0)
        ? '1/$liveShutterDenom'
        : settings.shutterSpeedLabel;
    final isoRaw = (isAuto && liveIso > 0) ? liveIso : settings.iso;
    final isoStr = '${_snapIso(isoRaw)}';
    final aptStr = !isAuto
        ? settings.apertureLabel
        : (liveAperture > 0 ? 'f/${liveAperture.toStringAsFixed(1)}' : '--');

    return Container(
      width: 68,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _LandscapeHudBtn(
            label: 'SS',
            value: ssStr,
            active: activePanel == _TopPanel.ssApt,
            onTap: () => onPanelTap(_TopPanel.ssApt),
          ),
          _LandscapeHudBtn(
            label: 'DEPTH',
            value: aptStr,
            active: activePanel == _TopPanel.apt,
            onTap: () => onPanelTap(_TopPanel.apt),
          ),
          // LEICA button
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onPanelTap(_TopPanel.looks);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: (settings.leicaLookEnabled || activePanel == _TopPanel.looks)
                    ? LeicaColors.red.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: (settings.leicaLookEnabled || activePanel == _TopPanel.looks)
                      ? LeicaColors.red.withValues(alpha: 0.55)
                      : Colors.white30,
                  width: 1,
                ),
              ),
              child: Text(
                'LEICA',
                style: TextStyle(
                  color: (settings.leicaLookEnabled || activePanel == _TopPanel.looks)
                      ? LeicaColors.red
                      : Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          _LandscapeHudBtn(
            label: 'WB',
            value: settings.wbLabel,
            active: activePanel == _TopPanel.wb,
            onTap: () => onPanelTap(_TopPanel.wb),
          ),
          _LandscapeHudBtn(
            label: 'ISO',
            value: isoStr,
            active: activePanel == _TopPanel.iso,
            onTap: () => onPanelTap(_TopPanel.iso),
          ),
        ],
      ),
    );
  }
}

class _LandscapeHudBtn extends StatelessWidget {
  const _LandscapeHudBtn({
    required this.label,
    required this.value,
    required this.active,
    required this.onTap,
  });
  final String label;
  final String value;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          color: active ? LeicaColors.red.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: active
              ? Border.all(color: LeicaColors.red.withValues(alpha: 0.55), width: 1)
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    color: LeicaColors.textDisabled,
                    fontSize: 7,
                    letterSpacing: 1.2)),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    color: LeicaColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// Right rail: vertical column of thumbnail / AUTO·PRO / shutter / flip / gear.
class _LandscapeRightRail extends StatelessWidget {
  const _LandscapeRightRail({
    required this.settings,
    required this.isCapturing,
    required this.lastCapturePath,
    required this.onCapture,
    required this.onSettingsChanged,
    required this.onSwitchCamera,
    required this.onOpenGallery,
    required this.onGearTap,
  });

  final CaptureSettings settings;
  final bool isCapturing;
  final String? lastCapturePath;
  final VoidCallback onCapture;
  final void Function(CaptureSettings Function(CaptureSettings)) onSettingsChanged;
  final VoidCallback onSwitchCamera;
  final VoidCallback onOpenGallery;
  final VoidCallback onGearTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _ThumbnailPreview(path: lastCapturePath, onTap: onOpenGallery),
          _ModePair(
            settings: settings,
            onModeChanged: (mode) =>
                onSettingsChanged((s) => s.copyWith(mode: mode)),
          ),
          ShutterButton(onPressed: onCapture, isCapturing: isCapturing),
          _BottomIconBtn(icon: Icons.flip_camera_ios, onTap: onSwitchCamera),
          _BottomIconBtn(icon: Icons.settings, onTap: onGearTap),
        ],
      ),
    );
  }
}

// ── Gear Panel ────────────────────────────────────────────────────────────────
// Slides up from the bottom as a semi-transparent overlay, 3×3 grid of buttons.
class _GearPanel extends StatelessWidget {
  const _GearPanel({
    required this.settings,
    required this.onDismiss,
    required this.onSettingsChanged,
    required this.onPanelActivate,
  });

  final CaptureSettings settings;
  final VoidCallback onDismiss;
  final void Function(CaptureSettings Function(CaptureSettings)) onSettingsChanged;
  final void Function(_TopPanel) onPanelActivate;

  IconData _flashIcon(FlashMode mode) => switch (mode) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        FlashMode.always => Icons.flash_on,
        FlashMode.torch => Icons.highlight,
      };

  String _flashLabel(FlashMode mode) => switch (mode) {
        FlashMode.off => 'OFF',
        FlashMode.auto => 'AUTO',
        FlashMode.always => 'ON',
        FlashMode.torch => 'TORCH',
      };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      child: Container(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {}, // prevent dismiss when tapping panel itself
            child: Container(
                margin: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  bottom: MediaQuery.of(context).padding.bottom + 90,
                ),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12), width: 1),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Row 1: FLASH · TIMER · ASPECT
                    _GearRow(children: [
                      _GearBtn(
                        icon: _flashIcon(settings.flashMode),
                        label: 'FLASH',
                        sublabel: _flashLabel(settings.flashMode),
                        active: settings.flashMode != FlashMode.off,
                        onTap: () {
                          final next = FlashMode.values[
                              (settings.flashMode.index + 1) %
                                  FlashMode.values.length];
                          onSettingsChanged(
                              (s) => s.copyWith(flashMode: next));
                        },
                      ),
                      _GearBtn(
                        icon: Icons.timer_outlined,
                        label: 'TIMER',
                        sublabel: settings.timerSeconds == 0
                            ? 'OFF'
                            : '${settings.timerSeconds}s',
                        active: settings.timerSeconds > 0,
                        onTap: () => onPanelActivate(_TopPanel.timer),
                      ),
                      _GearBtn(
                        icon: Icons.aspect_ratio,
                        label: 'ASPECT',
                        sublabel: settings.aspectRatio ==
                                CaptureAspectRatio.aspect4_3
                            ? '4:3'
                            : '16:9',
                        active: settings.aspectRatio ==
                            CaptureAspectRatio.aspect16_9,
                        onTap: () {
                          final next = settings.aspectRatio ==
                                  CaptureAspectRatio.aspect4_3
                              ? CaptureAspectRatio.aspect16_9
                              : CaptureAspectRatio.aspect4_3;
                          onSettingsChanged(
                              (s) => s.copyWith(aspectRatio: next));
                        },
                      ),
                    ]),
                    const SizedBox(height: 12),
                    // Row 2: VIEW · RAW · QUAL
                    _GearRow(children: [
                      _GearBtn(
                        icon: Icons.grid_on,
                        label: 'VIEW',
                        sublabel: 'GRID/LVL',
                        active: false,
                        onTap: () => onPanelActivate(_TopPanel.view),
                      ),
                      _GearBtn(
                        icon: settings.rawEnabled
                            ? Icons.raw_on
                            : Icons.raw_off,
                        label: 'RAW',
                        sublabel: settings.rawEnabled ? 'ON' : 'OFF',
                        active: settings.rawEnabled,
                        onTap: () => onSettingsChanged(
                            (s) => s.copyWith(rawEnabled: !s.rawEnabled)),
                      ),
                      _GearBtn(
                        icon: Icons.high_quality_outlined,
                        label: 'QUAL',
                        sublabel: settings.quality == CaptureQuality.heif
                            ? 'HEIF'
                            : settings.quality == CaptureQuality.high
                                ? 'HQ'
                                : 'STD',
                        active: settings.quality != CaptureQuality.standard,
                        onTap: () => onSettingsChanged((s) => s.copyWith(
                              quality: s.quality == CaptureQuality.standard
                                  ? CaptureQuality.high
                                  : s.quality == CaptureQuality.high
                                      ? CaptureQuality.heif
                                      : CaptureQuality.standard,
                            )),
                      ),
                    ]),
                  ],
                ),
            ),
          ),
        ),
      ),
    );
  }

}

class _GearRow extends StatelessWidget {
  const _GearRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: children,
    );
  }
}

class _GearBtn extends StatelessWidget {
  const _GearBtn({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String sublabel;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? Colors.white.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.10),
                border: Border.all(
                  color: active
                      ? Colors.white.withValues(alpha: 0.7)
                      : Colors.white.withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Icon(icon,
                  color: active ? Colors.white : Colors.white60, size: 22),
            ),
            const SizedBox(height: 5),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1)),
            Text(sublabel,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 8, letterSpacing: 0.5)),
          ],
        ),
      ),
    );
  }
}

// ── Portrait frame boundary line painter ─────────────────────────────────────
class _FrameLinePainter extends CustomPainter {
  const _FrameLinePainter({required this.topBar});
  final double topBar;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, topBar), Offset(size.width, topBar), paint);
    canvas.drawLine(
        Offset(0, size.height - topBar),
        Offset(size.width, size.height - topBar),
        paint);
  }

  @override
  bool shouldRepaint(_FrameLinePainter old) => old.topBar != topBar;
}

// ── Zoom Buttons ─────────────────────────────────────────────────────────────
// Native-camera-style 0.5× / 1× / 2× pills overlaid at the bottom of the preview.
class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({
    required this.availableZooms,
    required this.currentZoom,
    required this.onZoom,
  });
  final List<double> availableZooms;
  final double currentZoom;
  final ValueChanged<double> onZoom;

  String _label(double z) {
    if (z == z.truncateToDouble() && z >= 1) {
      return '${z.toInt()}×';
    }
    return '${z.toStringAsFixed(1)}×';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: availableZooms.map((z) {
        final isSelected = (z - currentZoom).abs() < 0.15;
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onZoom(z);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.black.withValues(alpha: 0.65)
                  : Colors.black.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(20),
              border: isSelected
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.55), width: 0.8)
                  : null,
            ),
            child: Text(
              _label(z),
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.70),
                fontSize: isSelected ? 13 : 12,
                fontWeight:
                    isSelected ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: 0.3,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Overlays ──────────────────────────────────────────────────────────────────
class _LookBadge extends StatelessWidget {
  const _LookBadge({required this.look, required this.leicaLookEnabled});
  final LeicaLook look;
  final bool leicaLookEnabled;

  @override
  Widget build(BuildContext context) {
    final label = leicaLookEnabled ? look.displayName.toUpperCase() : 'CLEAN';
    final color = leicaLookEnabled ? look.accentColor : Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: LeicaColors.overlay,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

// ── Utility widgets ───────────────────────────────────────────────────────────
class _ThumbnailPreview extends StatelessWidget {
  const _ThumbnailPreview({this.path, this.onTap});
  final String? path;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: path == null
          ? Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                border: Border.all(color: LeicaColors.midGray, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.photo_library_outlined,
                  color: LeicaColors.textDisabled, size: 20),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(File(path!),
                  width: 52, height: 52, fit: BoxFit.cover),
            ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
          color: LeicaColors.red, strokeWidth: 1.5),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Camera unavailable\n$error',
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: LeicaColors.textSecondary, fontSize: 13),
        ),
      ),
    );
  }
}

// ── Grid overlay (rule-of-thirds) ─────────────────────────────────────────────
class _GridOverlay extends StatelessWidget {
  const _GridOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridPainter(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1.0;
    canvas.drawLine(
        Offset(size.width / 3, 0), Offset(size.width / 3, size.height), paint);
    canvas.drawLine(
        Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), paint);
    canvas.drawLine(
        Offset(0, size.height / 3), Offset(size.width, size.height / 3), paint);
    canvas.drawLine(
        Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

// ── Level indicator (accelerometer-based horizon line) ────────────────────────
class _LevelIndicator extends StatefulWidget {
  const _LevelIndicator();

  @override
  State<_LevelIndicator> createState() => _LevelIndicatorState();
}

class _LevelIndicatorState extends State<_LevelIndicator> {
  StreamSubscription<AccelerometerEvent>? _sub;
  double _tilt = 0; // normalised x-axis, −1..+1

  @override
  void initState() {
    super.initState();
    _sub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval)
        .listen((e) {
      if (mounted) setState(() => _tilt = (e.x / 9.8).clamp(-1.0, 1.0));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _LevelPainter(tilt: _tilt),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  final double tilt;
  const _LevelPainter({required this.tilt});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final isLevel = tilt.abs() < 0.02;
    final color = isLevel ? const Color(0xFF44FF44) : Colors.white;

    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1.0;
    // Horizontal reference line
    canvas.drawLine(Offset(cx - 64, cy), Offset(cx + 64, cy), linePaint);

    // Fixed centre notch
    final notchPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(cx, cy - 10), Offset(cx, cy + 10), notchPaint);

    // Moving bubble — shifts up to ±56 px based on tilt
    final bubbleX = cx + (tilt * 280).clamp(-56.0, 56.0);
    canvas.drawCircle(
      Offset(bubbleX, cy),
      isLevel ? 6.0 : 5.0,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_LevelPainter old) => old.tilt != tilt;
}

// ── Face detection overlay ────────────────────────────────────────────────────
// Draws yellow squares around each face detected by Vision on the native side.
// [faces] contains normalized bounds (0–1, top-left origin) from the live stream.
class _FaceBoxOverlay extends StatelessWidget {
  const _FaceBoxOverlay({required this.faces, required this.previewSize});
  final List<Map<String, double>> faces;
  final Size previewSize;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: previewSize,
      painter: _FaceBoxPainter(faces: faces),
    );
  }
}

class _FaceBoxPainter extends CustomPainter {
  const _FaceBoxPainter({required this.faces});
  final List<Map<String, double>> faces;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFD700)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    for (final f in faces) {
      final x = (f['x'] ?? 0) * size.width;
      final y = (f['y'] ?? 0) * size.height;
      final w = (f['w'] ?? 0) * size.width;
      final h = (f['h'] ?? 0) * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    }
  }

  @override
  bool shouldRepaint(_FaceBoxPainter old) => old.faces != faces;
}

// ── Fullscreen photo viewer ────────────────────────────────────────────────────
class _PhotoViewPage extends StatelessWidget {
  const _PhotoViewPage({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              child: Image.file(File(path), fit: BoxFit.contain),
            ),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      child: const Icon(Icons.arrow_back_ios,
                          color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
