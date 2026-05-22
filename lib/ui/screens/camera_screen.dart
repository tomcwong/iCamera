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

final captureSettingsProvider =
    StateProvider<CaptureSettings>((ref) => const CaptureSettings());

const _isoValues = [
  50, 64, 100, 125, 200, 250, 400, 500, 800, 1000, 1600, 3200, 6400
];
const _shutterValues = [
  8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2, 1
];

// Which top-bar column is currently expanded in the display bar.
enum _TopPanel { ssApt, lens, wb, iso }

// ── Isolate helpers ───────────────────────────────────────────────────────────
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

Uint8List _encodeRgbaToJpeg(Map<String, dynamic> args) {
  final rgba = args['rgba'] as Uint8List;
  final width = args['width'] as int;
  final height = args['height'] as int;
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    order: img.ChannelOrder.rgba,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
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

  // UI state
  _TopPanel? _activeTopPanel;
  bool _showGearPanel = false;

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
    final applied =
        await ref.read(cameraControllerProvider.notifier).setZoomLevel(zoom);
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
    final xfile =
        await ref.read(cameraControllerProvider.notifier).capture();
    setState(() => _isCapturing = false);
    if (xfile == null) return;
    final settings = ref.read(captureSettingsProvider);
    final rotAngle = _captureRotationDegrees();
    _processAndSave(xfile, settings, rotAngle);
  }

  Future<void> _processAndSave(
      XFile xfile, CaptureSettings settings, int rotAngle) async {
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
        });
      } catch (_) {}

      if (decodeResult == null) {
        final path = await DngWriter.instance.save(xfile, asRaw: false);
        if (mounted) setState(() => _lastCapturePath = path);
        return;
      }

      // Crop to selected aspect ratio.
      if (settings.aspectRatio == CaptureAspectRatio.aspect16_9) {
        decodeResult = await compute(_cropToAspect, {
          'rgba': decodeResult['rgba'],
          'width': decodeResult['width'],
          'height': decodeResult['height'],
          'targetAspect': 16.0 / 9.0,
        });
      }

      final rgba = decodeResult['rgba'] as Uint8List;
      final width = decodeResult['width'] as int;
      final height = decodeResult['height'] as int;

      Float32List? mask;
      if (settings.bokehEnabled && settings.mode == CaptureMode.aperture) {
        mask = await ref
            .read(segmentationServiceProvider)
            .segment(File(xfile.path));
      }

      final processedRgba = await ref.read(imagePipelineProvider).process(
            rgba: rgba,
            width: width,
            height: height,
            settings: settings,
            segmentationMask: mask,
          );

      final jpegBytes = await compute(_encodeRgbaToJpeg, {
        'rgba': processedRgba,
        'width': width,
        'height': height,
      });

      final path = await DngWriter.instance.saveProcessedJpeg(jpegBytes);
      if (mounted) setState(() => _lastCapturePath = path);
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
  }

  void _toggleTopPanel(_TopPanel panel) {
    setState(() {
      _activeTopPanel = _activeTopPanel == panel ? null : panel;
      if (_activeTopPanel != null) _showGearPanel = false;
    });
  }

  void _openGallery() => ManualCameraService.instance.openGallery();

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraControllerProvider);
    final settings = ref.watch(captureSettingsProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    ref.listen<CaptureSettings>(captureSettingsProvider, (prev, next) {
      ref.read(cameraControllerProvider.notifier).applyManualSettings(next);
      if (prev?.quality != next.quality) {
        ref.read(cameraControllerProvider.notifier).setQuality(next.quality);
      }
    });

    // Preview aspect ratio: natural sensor ratio (3:4 portrait, 4:3 landscape).
    // 16:9 selection shows a crop overlay; the final image is cropped on capture.
    final previewAspect = isLandscape ? 4.0 / 3.0 : 3.0 / 4.0;

    Widget previewWidget = cameraState.when(
      data: (ctrl) => ctrl != null && ctrl.value.isInitialized
          ? _CameraPreview(controller: ctrl, settings: settings)
          : const _LoadingView(),
      loading: () => const _LoadingView(),
      error: (e, _) => _ErrorView(error: e.toString()),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Main column layout ──────────────────────────────────────
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // Top HUD
                _TopHud(
                  settings: settings,
                  activePanel: _activeTopPanel,
                  onPanelTap: _toggleTopPanel,
                ),

                // Preview area
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (_) => _baseZoom = _currentZoom,
                    onScaleUpdate: (d) {
                      if (d.pointerCount >= 2) {
                        _setZoom((_baseZoom * d.scale).clamp(1.0, 10.0));
                      }
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Constrained preview — fixes portrait compression bug
                        Center(
                          child: AspectRatio(
                            aspectRatio: previewAspect,
                            child: previewWidget,
                          ),
                        ),
                        // 16:9 crop overlay
                        if (settings.aspectRatio ==
                            CaptureAspectRatio.aspect16_9)
                          Center(
                            child: AspectRatio(
                              aspectRatio: previewAspect,
                              child: _AspectCropOverlay(
                                  isLandscape: isLandscape),
                            ),
                          ),
                        // Zoom indicator
                        if (_zoomIndicatorVisible)
                          Positioned(
                            bottom: 12,
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
                      ],
                    ),
                  ),
                ),

                // Display bar — contextual selector, animates in/out
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  child: _activeTopPanel != null
                      ? _DisplayBar(
                          panel: _activeTopPanel!,
                          settings: settings,
                          onSettingsChanged: _updateSettings,
                          onWbChanged: (k) => _updateSettings(
                              (s) => s.copyWith(whiteBalanceKelvin: k)),
                        )
                      : const SizedBox.shrink(),
                ),

                // Bottom bar
                _BottomBar(
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

                // Bottom safe area padding
                SizedBox(
                    height: MediaQuery.of(context).padding.bottom +
                        (isLandscape ? 4 : 8)),
              ],
            ),
          ),

          // ── Gear panel overlay ──────────────────────────────────────
          if (_showGearPanel)
            Positioned.fill(
              child: _GearPanel(
                settings: settings,
                onDismiss: () => setState(() => _showGearPanel = false),
                onSettingsChanged: _updateSettings,
                onPanelActivate: (panel) {
                  setState(() {
                    _showGearPanel = false;
                    _activeTopPanel = panel;
                  });
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ── Camera Preview ────────────────────────────────────────────────────────────
class _CameraPreview extends StatelessWidget {
  const _CameraPreview(
      {required this.controller, required this.settings});

  final CameraController controller;
  final CaptureSettings settings;

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
    final previewSize = controller.value.previewSize!;
    final int turns = _quarterTurns(controller.description);
    final int sensor = controller.description.sensorOrientation;
    final bool deviceLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final bool pluginRotates = !deviceLandscape &&
        Platform.isAndroid &&
        turns == 0 &&
        (sensor == 90 || sensor == 270);
    final bool swapDims = (turns % 2 == 1) || pluginRotates;
    final double displayW =
        swapDims ? previewSize.height : previewSize.width;
    final double displayH =
        swapDims ? previewSize.width : previewSize.height;

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
                  colorFilter: ColorFilter.matrix(
                      settings.selectedLook.previewMatrix),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix(
                        _CameraPreview._wbMatrix(
                            settings.whiteBalanceKelvin)),
                    child: CameraPreview(controller),
                  ),
                ),
              ),
            ),
          ),
          _VignetteOverlay(strength: settings.selectedLens.vignetteStrength),
          _LensTintOverlay(tint: settings.selectedLens.previewTint),
          // Look badge — top-right corner of the preview box
          Positioned(
            top: 8,
            right: 8,
            child: _LookBadge(look: settings.selectedLook),
          ),
        ],
      ),
    );
  }
}

// ── Aspect ratio crop overlay ─────────────────────────────────────────────────
// Dims the area outside the selected crop (shown when 16:9 is active).
class _AspectCropOverlay extends StatelessWidget {
  const _AspectCropOverlay({required this.isLandscape});
  final bool isLandscape;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final W = constraints.maxWidth;
      final H = constraints.maxHeight;
      const dim = Color(0xAA000000);

      // Landscape preview is 4:3; 16:9 crop removes top/bottom.
      // Portrait preview is 3:4; 9:16 crop removes left/right.
      double left = 0, top = 0, right = 0, bottom = 0;
      if (isLandscape) {
        final cropH = W * 9 / 16;
        final bar = ((H - cropH) / 2).clamp(0.0, H);
        top = bar;
        bottom = bar;
      } else {
        final cropW = H * 9 / 16;
        final bar = ((W - cropW) / 2).clamp(0.0, W);
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
// New order: SS/APT | iCamera | WB | ISO
class _TopHud extends StatelessWidget {
  const _TopHud({
    required this.settings,
    required this.activePanel,
    required this.onPanelTap,
  });

  final CaptureSettings settings;
  final _TopPanel? activePanel;
  final void Function(_TopPanel) onPanelTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: EdgeInsets.only(
        top: 8,
        left: 12,
        right: 12,
        bottom: 8,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // SS / APT — combined left column
          _HudTap(
            active: activePanel == _TopPanel.ssApt,
            onTap: () => onPanelTap(_TopPanel.ssApt),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('SS',
                        style: TextStyle(
                            color: LeicaColors.textDisabled,
                            fontSize: 7,
                            letterSpacing: 1.5)),
                    const SizedBox(width: 10),
                    const Text('APT',
                        style: TextStyle(
                            color: LeicaColors.textDisabled,
                            fontSize: 7,
                            letterSpacing: 1.5)),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(settings.shutterSpeedLabel,
                        style: const TextStyle(
                            color: LeicaColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(width: 6),
                    Text(settings.apertureLabel,
                        style: const TextStyle(
                            color: LeicaColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ],
            ),
          ),

          // iCamera / lens name — center
          _HudTap(
            active: activePanel == _TopPanel.lens,
            onTap: () => onPanelTap(_TopPanel.lens),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'iCamera',
                  style: TextStyle(
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
                  CaptureSettings.wbLabels[
                      CaptureSettings.wbPresets
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
                Text(settings.isoLabel,
                    style: const TextStyle(
                        color: LeicaColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Tappable HUD column with active highlight
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
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
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
  });

  final _TopPanel panel;
  final CaptureSettings settings;
  final void Function(CaptureSettings Function(CaptureSettings)) onSettingsChanged;
  final ValueChanged<int> onWbChanged;

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
        _TopPanel.iso => _IsoPanel(
            settings: settings,
            onSettingsChanged: onSettingsChanged,
          ),
      },
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
            'AUTO — SS and APT controlled automatically',
            style: TextStyle(
                color: LeicaColors.textSecondary,
                fontSize: 10,
                letterSpacing: 0.5),
          ),
        ),
      );
    }
    if (settings.mode == CaptureMode.aperture) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ApertureDial(
              aperture: settings.aperture,
              maxAperture: settings.selectedLens.maxAperture,
              onChanged: (apt) =>
                  onSettingsChanged((s) => s.copyWith(aperture: apt)),
            ),
            const SizedBox(width: 24),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('BOKEH',
                    style: TextStyle(
                        color: LeicaColors.textDisabled,
                        fontSize: 9,
                        letterSpacing: 1.5)),
                const SizedBox(height: 4),
                Switch(
                  value: settings.bokehEnabled,
                  onChanged: (v) =>
                      onSettingsChanged((s) => s.copyWith(bokehEnabled: v)),
                  activeThumbColor: LeicaColors.red,
                ),
              ],
            ),
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MiniModeChip(
              label: 'AUTO',
              selected: settings.mode == CaptureMode.auto,
              onTap: () {
                HapticFeedback.selectionClick();
                onModeChanged(CaptureMode.auto);
              },
            ),
            const SizedBox(width: 4),
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
      ],
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
                        icon: Icons.grid_on,
                        label: 'VIEW',
                        sublabel: 'SOON',
                        active: false,
                        onTap: onDismiss,
                      ),
                      _GearBtn(
                        icon: Icons.timer_outlined,
                        label: 'TIMER',
                        sublabel: 'SOON',
                        active: false,
                        onTap: onDismiss,
                      ),
                    ]),
                    const SizedBox(height: 12),
                    _GearRow(children: [
                      _GearBtn(
                        icon: Icons.shutter_speed,
                        label: 'SS',
                        sublabel: settings.shutterSpeedLabel,
                        active: settings.mode == CaptureMode.manual,
                        onTap: () {
                          if (settings.mode != CaptureMode.manual) {
                            onSettingsChanged(
                                (s) => s.copyWith(mode: CaptureMode.manual));
                          }
                          onPanelActivate(_TopPanel.ssApt);
                        },
                      ),
                      _GearBtn(
                        icon: Icons.palette_outlined,
                        label: 'LOOKS',
                        sublabel: settings.selectedLook.displayName
                            .toUpperCase(),
                        active: false,
                        onTap: () => _showLooksSheet(context),
                      ),
                      _GearBtn(
                        icon: Icons.camera_outlined,
                        label: 'APT',
                        sublabel: settings.apertureLabel,
                        active: settings.mode == CaptureMode.aperture,
                        onTap: () {
                          onSettingsChanged((s) => s.copyWith(
                              mode: s.mode == CaptureMode.aperture
                                  ? CaptureMode.auto
                                  : CaptureMode.aperture));
                          onPanelActivate(_TopPanel.ssApt);
                        },
                      ),
                    ]),
                    const SizedBox(height: 12),
                    _GearRow(children: [
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
                      _GearBtn(
                        icon: settings.rawEnabled
                            ? Icons.raw_on
                            : Icons.raw_off,
                        label: 'FILM',
                        sublabel: settings.rawEnabled ? 'RAW' : 'JPEG',
                        active: settings.rawEnabled,
                        onTap: () => onSettingsChanged(
                            (s) => s.copyWith(rawEnabled: !s.rawEnabled)),
                      ),
                      // Quality toggle
                      _GearBtn(
                        icon: Icons.high_quality_outlined,
                        label: 'QUAL',
                        sublabel: settings.quality == CaptureQuality.high
                            ? 'HQ'
                            : 'STD',
                        active: settings.quality == CaptureQuality.high,
                        onTap: () => onSettingsChanged((s) => s.copyWith(
                              quality: s.quality == CaptureQuality.standard
                                  ? CaptureQuality.high
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

  void _showLooksSheet(BuildContext context) {
    onDismiss();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: LookSelector(
          selected: settings.selectedLook,
          onSelected: (look) {
            onSettingsChanged((s) => s.copyWith(selectedLook: look));
            Navigator.pop(context);
          },
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

// ── Overlays ──────────────────────────────────────────────────────────────────
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
        border:
            Border.all(color: look.accentColor.withValues(alpha: 0.6), width: 1),
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

// ── Utility widgets ───────────────────────────────────────────────────────────
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
