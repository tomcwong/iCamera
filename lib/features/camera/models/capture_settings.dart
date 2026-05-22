import 'package:camera/camera.dart';
import '../../color_science/leica_looks.dart';
import '../../lens_simulation/lens_profile.dart';

enum CaptureMode { auto, manual, aperture }

enum CaptureQuality { standard, high }

/// 4:3 = natural sensor ratio (default). 16:9 = cropped wide.
enum CaptureAspectRatio { aspect4_3, aspect16_9 }

class CaptureSettings {
  const CaptureSettings({
    this.mode = CaptureMode.auto,
    this.iso = 100,
    this.shutterSpeedDenominator = 60,
    this.whiteBalanceKelvin = 5500,
    this.aperture = 5.6,
    this.selectedLook = LeicaLook.classic,
    this.selectedLens = LensProfile.noctilux50,
    this.flashMode = FlashMode.off,
    this.rawEnabled = false,
    this.bokehEnabled = false,
    this.exposureCompensation = 0.0,
    this.quality = CaptureQuality.standard,
    this.aspectRatio = CaptureAspectRatio.aspect4_3,
  });

  final CaptureMode mode;
  final int iso;
  final int shutterSpeedDenominator;
  final int whiteBalanceKelvin;
  final double aperture;
  final LeicaLook selectedLook;
  final LensProfile selectedLens;
  final FlashMode flashMode;
  final bool rawEnabled;
  final bool bokehEnabled;
  final double exposureCompensation;
  final CaptureQuality quality;
  final CaptureAspectRatio aspectRatio;

  static const List<int> wbPresets = [2800, 3500, 4500, 5500, 6500, 8000];
  static const List<String> wbLabels = ['Bulb', 'Indoor', 'Fluorescent', 'Daylight', 'Cloudy', 'Shade'];

  String get shutterSpeedLabel => '1/$shutterSpeedDenominator';
  String get isoLabel => 'ISO $iso';
  String get apertureLabel => 'f/${aperture.toStringAsFixed(1)}';
  String get wbLabel => '${whiteBalanceKelvin}K';

  CaptureSettings copyWith({
    CaptureMode? mode,
    int? iso,
    int? shutterSpeedDenominator,
    int? whiteBalanceKelvin,
    double? aperture,
    LeicaLook? selectedLook,
    LensProfile? selectedLens,
    FlashMode? flashMode,
    bool? rawEnabled,
    bool? bokehEnabled,
    double? exposureCompensation,
    CaptureQuality? quality,
    CaptureAspectRatio? aspectRatio,
  }) {
    return CaptureSettings(
      mode: mode ?? this.mode,
      iso: iso ?? this.iso,
      shutterSpeedDenominator: shutterSpeedDenominator ?? this.shutterSpeedDenominator,
      whiteBalanceKelvin: whiteBalanceKelvin ?? this.whiteBalanceKelvin,
      aperture: aperture ?? this.aperture,
      selectedLook: selectedLook ?? this.selectedLook,
      selectedLens: selectedLens ?? this.selectedLens,
      flashMode: flashMode ?? this.flashMode,
      rawEnabled: rawEnabled ?? this.rawEnabled,
      bokehEnabled: bokehEnabled ?? this.bokehEnabled,
      exposureCompensation: exposureCompensation ?? this.exposureCompensation,
      quality: quality ?? this.quality,
      aspectRatio: aspectRatio ?? this.aspectRatio,
    );
  }
}
