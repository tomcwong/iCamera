import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
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
import '../widgets/aperture_dial.dart';
import '../widgets/exposure_wheel.dart';
import '../widgets/look_selector.dart';
import '../widgets/wb_selector.dart';
import '../widgets/lens_selector.dart';
import '../widgets/controls_bar.dart';

final captureSettingsProvider = StateProvider<CaptureSettings>((ref) => const CaptureSettings());

const _isoValues = [50, 64, 100, 125, 200, 250, 400, 500, 800, 1000, 1600, 3200, 6400];
const _shutterValues = [8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1];

// ── Isolate helpers (must be top-level for compute()) ────────────────────────
// Runs JPEG decode + rotation on a background isolate so the UI never freezes.
Map<String, dynamic> _decodeAndRotate(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final angle = args['angle'] as int;
  var decoded = img.decodeJpg(bytes)!;
  if (angle != 0) decoded = img.copyRotate(decoded, angle: angle);
  return {
    'rgba': Uint8List.fromList(decoded.getBytes(order: img.ChannelOrder.rgba)),
    'width': decoded.width,
    'height': decoded.height,
  };
}

// Runs JPEG re-encode on a background isolate — this is the biggest bottleneck.
Uint8List _encodeRgbaToJpeg(Map<String, dynamic> args) {
  final rgba  = args['rgba']   as Uint8List;
  final width = args['width']  as int;
  final height= args['height'] as int;
  final image = img.Image.fromBytes(
    width: width, height: height,
    bytes: rgba.buffer,
    order: img.ChannelOrder.rgba,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> with WidgetsBindingObserver {
  bool _isCapturing = false;
  String? _lastCapturePath;
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  bool _zoomIndicatorVisible = false;
  Timer? _zoomHideTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.read(lutPreloadProvider);
  }

  @override
  void dispose() {
    _zoomHideTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _setZoom(double zoom) async {
    final applied = await ref.read(cameraControllerProvider.notifier).setZoomLevel(zoom);
    if (!mounted) return;
    setState(() {
      _currentZoom = applied;
      _zoomIndicatorVisible = true;
    });
    _zoomHideTimer?.cancel();
    _zoomHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _zoomIndicatorVisible = false);
    });
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Re-apply immersive mode after orientation change (Android clears it on rotation).
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
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    // Physical capture — blocks only for the sensor exposure time (~0.2s).
    final xfile = await ref.read(cameraControllerProvider.notifier).capture();

    // Release shutter immediately so the user can take the next shot.
    // Processing continues in the background below.
    setState(() => _isCapturing = false);

    if (xfile == null) return;

    // Snapshot settings at capture time before the user can change them.
    final settings = ref.read(captureSettingsProvider);
    final rotAngle = _captureRotationDegrees();

    // Fire-and-forget: process and save without blocking the camera UI.
    _processAndSave(xfile, settings, rotAngle);
  }

  Future<void> _processAndSave(XFile xfile, CaptureSettings settings, int rotAngle) async {
    try {
      // RAW/DNG: save original bytes unmodified.
      if (settings.rawEnabled) {
        final path = await DngWriter.instance.save(xfile, asRaw: true);
        if (mounted) setState(() => _lastCapturePath = path);
        return;
      }

      // Decode + rotate on background isolate.
      final rawBytes = await xfile.readAsBytes();
      Map<String, dynamic>? decodeResult;
      try {
        decodeResult = await compute(_decodeAndRotate, {
          'bytes': rawBytes,
          'angle': rotAngle,
        });
      } catch (_) {}

      if (decodeResult == null) {
        final path = await DngWriter.instance.save(xfile, asRaw: false);
        if (mounted) setState(() => _lastCapturePath = path);
        return;
      }

      final rgba   = decodeResult['rgba']   as Uint8List;
      final width  = decodeResult['width']  as int;
      final height = decodeResult['height'] as int;

      // Segmentation mask for bokeh mode.
      Float32List? mask;
      if (settings.bokehEnabled && settings.mode == CaptureMode.aperture) {
        mask = await ref.read(segmentationServiceProvider).segment(File(xfile.path));
      }

      // C++ pipeline: LUT → exposure → WB → tone → vignette → CA → bokeh.
      final processedRgba = await ref.read(imagePipelineProvider).process(
        rgba: rgba,
        width: width,
        height: height,
        settings: settings,
        segmentationMask: mask,
      );

      // Re-encode on background isolate.
      final jpegBytes = await compute(_encodeRgbaToJpeg, {
        'rgba': processedRgba,
        'width': width,
        'height': height,
      });

      final path = await DngWriter.instance.saveProcessedJpeg(jpegBytes);
      if (mounted) setState(() => _lastCapturePath = path);
    } catch (_) {
      // Non-fatal: processing failure silently discards the frame.
    }
  }

  /// Degrees to rotate the captured JPEG to match the live preview orientation.
  /// Only sensor=0° needs manual correction; all other orientations are handled
  /// by camera_android_camerax via EXIF, which img.decodeJpg applies automatically.
  int _captureRotationDegrees() {
    if (!Platform.isAndroid) return 0;
    final ctrl = ref.read(cameraControllerProvider).value;
    if (ctrl?.description.sensorOrientation == 0) return 180;
    return 0;
  }

  void _cycleWb() {
    final current = ref.read(captureSettingsProvider).whiteBalanceKelvin;
    final idx = CaptureSettings.wbPresets.indexOf(current);
    final next = CaptureSettings.wbPresets[(idx + 1) % CaptureSettings.wbPresets.length];
    _updateSettings((s) => s.copyWith(whiteBalanceKelvin: next));
  }

  void _updateSettings(CaptureSettings Function(CaptureSettings) update) {
    final prev = ref.read(captureSettingsProvider);
    ref.read(captureSettingsProvider.notifier).update(update);
    final next = ref.read(captureSettingsProvider);
    if (prev.selectedLens != next.selectedLens) {
      _setZoom(next.selectedLens.defaultZoom);
    }
  }

  void _openGallery() {
    ManualCameraService.instance.openGallery();
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraControllerProvider);
    final settings = ref.watch(captureSettingsProvider);

    // Apply hardware exposure settings whenever the user changes ISO or mode.
    // Re-init the camera when quality changes (different ResolutionPreset needed).
    ref.listen<CaptureSettings>(captureSettingsProvider, (prev, next) {
      ref.read(cameraControllerProvider.notifier).applyManualSettings(next);
      if (prev?.quality != next.quality) {
        ref.read(cameraControllerProvider.notifier).setQuality(next.quality);
      }
    });

    return Scaffold(
      backgroundColor: LeicaColors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera Preview ──────────────────────────────────────
          cameraState.when(
            data: (ctrl) => ctrl != null && ctrl.value.isInitialized
                ? _CameraPreview(controller: ctrl, settings: settings)
                : const _LoadingView(),
            loading: () => const _LoadingView(),
            error: (e, _) => _ErrorView(error: e.toString()),
          ),

          // ── Pinch-to-zoom gesture layer — opaque so camera preview doesn't steal gesture ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (details) {
              _baseZoom = _currentZoom;
            },
            onScaleUpdate: (details) {
              if (details.pointerCount >= 2) {
                _setZoom((_baseZoom * details.scale).clamp(1.0, 10.0));
              }
            },
          ),

          // ── Zoom level indicator (fades after 2s) ───────────────
          if (_zoomIndicatorVisible)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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

          // ── Top HUD (metadata) ──────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopHud(settings: settings, onWbTap: _cycleWb),
          ),

          // ── Bottom Controls (same layout in portrait and landscape) ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _BottomControls(
              settings: settings,
              isCapturing: _isCapturing,
              lastCapturePath: _lastCapturePath,
              onCapture: _capture,
              onSettingsChanged: _updateSettings,
              onWbChanged: (k) => _updateSettings((s) => s.copyWith(whiteBalanceKelvin: k)),
              onSwitchCamera: () => ref.read(cameraControllerProvider.notifier).switchCamera(),
              onOpenGallery: _openGallery,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Camera Preview with lens vignette overlay ────────────────────────────────
class _CameraPreview extends StatelessWidget {
  const _CameraPreview({required this.controller, required this.settings});

  final CameraController controller;
  final CaptureSettings settings;

  // Number of 90° CW turns needed to correct the preview orientation.
  // On Android the CameraX Texture may output raw (unrotated) sensor frames;
  // we rotate manually based on the physical sensor mounting angle.
  // On iOS, AVFoundation handles this inside CameraPreview — no correction needed.
  static List<double> _wbMatrix(int kelvin) {
    // t < 0 = warm light (Bulb/Indoor) → cool correction: cut R, boost B
    // t > 0 = cool light (Cloudy/Shade) → warm correction: boost R, cut B
    final t = (kelvin - 5500) / 4500.0;
    final r = (1.0 + t * 0.50).clamp(0.5, 1.5);
    final b = (1.0 - t * 0.58).clamp(0.5, 1.8);
    return [r, 0, 0, 0, 0,  0, 1, 0, 0, 0,  0, 0, b, 0, 0,  0, 0, 0, 1, 0];
  }

  static int _quarterTurns(CameraDescription camera) {
    if (!Platform.isAndroid) return 0;
    // camera_android_camerax handles standard orientations (90/180/270) itself.
    // Only sensor=0° (physically upside-down sensor) is not corrected by the
    // plugin and needs a manual 180° flip (2 quarter turns).
    return camera.sensorOrientation == 0 ? 2 : 0;
  }

  @override
  Widget build(BuildContext context) {
    final previewSize = controller.value.previewSize!;
    final int turns = _quarterTurns(controller.description);
    final int sensor = controller.description.sensorOrientation;
    // Swap width/height when either:
    // (a) we manually rotate 90° or 270°, OR
    // (b) camera_android_camerax rotates internally (sensor=90/270, turns=0) —
    //     in that case previewSize is still in raw landscape sensor coords but
    //     CameraPreview outputs portrait, so we must swap to get the right ratio.
    // In landscape, CameraX tracks the device rotation and aligns its output to
    // landscape — no portrait swap needed. Only apply the swap in portrait mode.
    final bool deviceLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final bool pluginRotates = !deviceLandscape &&
        Platform.isAndroid && turns == 0 &&
        (sensor == 90 || sensor == 270);
    final bool swapDims = (turns % 2 == 1) || pluginRotates;
    final double displayW = swapDims ? previewSize.height : previewSize.width;
    final double displayH = swapDims ? previewSize.width  : previewSize.height;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: displayW,
              height: displayH,
              child: RotatedBox(
                quarterTurns: turns,
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(settings.selectedLook.previewMatrix),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix(
                        _CameraPreview._wbMatrix(settings.whiteBalanceKelvin)),
                    child: CameraPreview(controller),
                  ),
                ),
              ),
            ),
          ),
          // Vignette overlay (rendered as radial gradient matching lens profile)
          _VignetteOverlay(strength: settings.selectedLens.vignetteStrength),
          // Lens colour-tint overlay — makes lens switching visible in the preview
          _LensTintOverlay(tint: settings.selectedLens.previewTint),
          // Look name watermark
          Positioned(
            top: 80,
            right: 16,
            child: _LookBadge(look: settings.selectedLook),
          ),
        ],
      ),
    );
  }
}

class _VignetteOverlay extends StatelessWidget {
  const _VignetteOverlay({required this.strength});
  final double strength;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.0,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: strength * 0.9),
            ],
            stops: const [0.2, 1.0],
          ),
        ),
      ),
    );
  }
}

class _LensTintOverlay extends StatelessWidget {
  const _LensTintOverlay({required this.tint});
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(color: tint),
      ),
    );
  }
}

class _LookBadge extends StatelessWidget {
  const _LookBadge({required this.look});
  final LeicaLook look;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: LeicaColors.overlay,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: look.accentColor.withValues(alpha: 0.6), width: 1),
      ),
      child: Text(
        look.displayName.toUpperCase(),
        style: TextStyle(
          color: look.accentColor,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

// ── Top HUD ──────────────────────────────────────────────────────────────────
class _TopHud extends StatelessWidget {
  const _TopHud({required this.settings, required this.onWbTap});
  final CaptureSettings settings;
  final VoidCallback onWbTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 16,
        bottom: 8,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [LeicaColors.overlay, Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _HudValue(label: 'SS', value: settings.shutterSpeedLabel),
          _HudValue(label: 'ISO', value: settings.isoLabel),
          // Center: lens name
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'iCamera',
                style: const TextStyle(
                  color: LeicaColors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 4,
                ),
              ),
              Text(
                settings.selectedLens.displayName.toUpperCase(),
                style: const TextStyle(
                  color: LeicaColors.textSecondary,
                  fontSize: 8,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
          GestureDetector(
            onTap: onWbTap,
            child: _HudValue(
              label: 'WB',
              value: settings.wbLabel,
              sub: CaptureSettings.wbLabels[
                CaptureSettings.wbPresets.indexOf(settings.whiteBalanceKelvin)
                    .clamp(0, CaptureSettings.wbLabels.length - 1)],
            ),
          ),
          _HudValue(label: 'APT', value: settings.apertureLabel),
        ],
      ),
    );
  }
}

class _HudValue extends StatelessWidget {
  const _HudValue({required this.label, required this.value, this.sub});
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: const TextStyle(color: LeicaColors.textDisabled, fontSize: 8, letterSpacing: 1.5)),
        Text(value, style: const TextStyle(color: LeicaColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
        if (sub != null)
          Text(sub!, style: const TextStyle(color: Colors.white, fontSize: 7, letterSpacing: 1)),
      ],
    );
  }
}

// ── Bottom Controls ───────────────────────────────────────────────────────────
class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.settings,
    required this.isCapturing,
    required this.lastCapturePath,
    required this.onCapture,
    required this.onSettingsChanged,
    required this.onWbChanged,
    required this.onSwitchCamera,
    required this.onOpenGallery,
  });

  final CaptureSettings settings;
  final bool isCapturing;
  final String? lastCapturePath;
  final VoidCallback onCapture;
  final void Function(CaptureSettings Function(CaptureSettings)) onSettingsChanged;
  final ValueChanged<int> onWbChanged;
  final VoidCallback onSwitchCamera;
  final VoidCallback onOpenGallery;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.only(bottom: bottomPad + 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [LeicaColors.overlay, Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Look selector + Lens selector on the same row
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: LookSelector(
                  selected: settings.selectedLook,
                  onSelected: (look) => onSettingsChanged((s) => s.copyWith(selectedLook: look)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: LensSelector(
                  selected: settings.selectedLens,
                  onSelected: (lens) => onSettingsChanged((s) => s.copyWith(
                        selectedLens: lens,
                        aperture: lens.maxAperture,
                      )),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // WB selector (includes its own "WB:" label)
          WbSelector(
            selectedKelvin: settings.whiteBalanceKelvin,
            onSelected: onWbChanged,
          ),
          const SizedBox(height: 12),

          // Manual controls (shown only in PRO / APT mode)
          if (settings.mode != CaptureMode.auto) ...[
            if (settings.mode == CaptureMode.manual) ...[
              Row(
                children: [
                  Expanded(
                    child: ExposureWheel(
                      values: _shutterValues.map((v) => '1/$v').toList(),
                      selectedIndex: _shutterValues.indexOf(settings.shutterSpeedDenominator).clamp(0, _shutterValues.length - 1),
                      onChanged: (i) => onSettingsChanged((s) => s.copyWith(shutterSpeedDenominator: _shutterValues[i])),
                      label: 'SHUTTER',
                    ),
                  ),
                  Expanded(
                    child: ExposureWheel(
                      values: _isoValues.map((v) => v.toString()).toList(),
                      selectedIndex: _isoValues.indexOf(settings.iso).clamp(0, _isoValues.length - 1),
                      onChanged: (i) => onSettingsChanged((s) => s.copyWith(iso: _isoValues[i])),
                      label: 'ISO',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (settings.mode == CaptureMode.aperture) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ApertureDial(
                    aperture: settings.aperture,
                    maxAperture: settings.selectedLens.maxAperture,
                    onChanged: (apt) => onSettingsChanged((s) => s.copyWith(aperture: apt)),
                  ),
                  const SizedBox(width: 24),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('BOKEH', style: TextStyle(color: LeicaColors.textDisabled, fontSize: 9, letterSpacing: 1.5)),
                      const SizedBox(height: 4),
                      Switch(
                        value: settings.bokehEnabled,
                        onChanged: (v) => onSettingsChanged((s) => s.copyWith(bokehEnabled: v)),
                        activeThumbColor: LeicaColors.red,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ],

          // Controls bar (mode selector, flash, RAW, flip, quality)
          ControlsBar(
            settings: settings,
            onModeChanged: (mode) => onSettingsChanged((s) => s.copyWith(mode: mode)),
            onRawToggled: () => onSettingsChanged((s) => s.copyWith(rawEnabled: !s.rawEnabled)),
            onFlashToggled: () {
              final next = FlashMode.values[(settings.flashMode.index + 1) % FlashMode.values.length];
              onSettingsChanged((s) => s.copyWith(flashMode: next));
            },
            onSwitchCamera: onSwitchCamera,
            onQualityToggled: () => onSettingsChanged((s) => s.copyWith(
              quality: s.quality == CaptureQuality.standard
                  ? CaptureQuality.high
                  : CaptureQuality.standard,
            )),
          ),
          const SizedBox(height: 16),

          // Shutter row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Last capture thumbnail — tap to open system gallery
              _ThumbnailPreview(path: lastCapturePath, onTap: onOpenGallery),

              // Shutter button
              ShutterButton(onPressed: onCapture, isCapturing: isCapturing),

              // Placeholder (right balance)
              const SizedBox(width: 52),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThumbnailPreview extends StatelessWidget {
  const _ThumbnailPreview({this.path, this.onTap});
  final String? path;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (path == null) {
      return Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          border: Border.all(color: LeicaColors.midGray, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(File(path!), width: 52, height: 52, fit: BoxFit.cover),
      ),
    );
  }
}

// ── Utility views ─────────────────────────────────────────────────────────────
class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: LeicaColors.red, strokeWidth: 1.5),
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
          style: const TextStyle(color: LeicaColors.textSecondary, fontSize: 13),
        ),
      ),
    );
  }
}
