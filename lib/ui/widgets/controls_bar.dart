import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/leica_colors.dart';
import '../../features/camera/models/capture_settings.dart';

class ControlsBar extends StatelessWidget {
  const ControlsBar({
    super.key,
    required this.settings,
    required this.onModeChanged,
    required this.onRawToggled,
    required this.onFlashToggled,
    required this.onSwitchCamera,
    required this.onQualityToggled,
    this.vertical = false,
  });

  final CaptureSettings settings;
  final ValueChanged<CaptureMode> onModeChanged;
  final VoidCallback onRawToggled;
  final VoidCallback onFlashToggled;
  final VoidCallback onSwitchCamera;
  final VoidCallback onQualityToggled;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final items = [
      _IconBtn(
        icon: settings.rawEnabled ? Icons.raw_on : Icons.raw_off,
        label: 'RAW',
        active: settings.rawEnabled,
        onTap: onRawToggled,
      ),
      _ModeChip(
        label: 'AUTO',
        selected: settings.mode == CaptureMode.auto,
        onTap: () => onModeChanged(CaptureMode.auto),
      ),
      _ModeChip(
        label: 'PRO',
        selected: settings.mode == CaptureMode.manual,
        onTap: () => onModeChanged(CaptureMode.manual),
      ),
      _ModeChip(
        label: 'APT',
        selected: settings.mode == CaptureMode.aperture,
        onTap: () => onModeChanged(CaptureMode.aperture),
      ),
      _IconBtn(
        icon: _flashIcon(settings.flashMode),
        label: 'FLASH',
        active: settings.flashMode != FlashMode.off,
        onTap: onFlashToggled,
      ),
      _IconBtn(
        icon: Icons.flip_camera_ios,
        label: 'FLIP',
        active: false,
        onTap: onSwitchCamera,
      ),
      _QualityBtn(
        isHigh: settings.quality == CaptureQuality.high,
        onTap: onQualityToggled,
      ),
    ];

    if (vertical) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: items
            .map((item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: item,
                ))
            .toList(),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: items,
    );
  }

  IconData _flashIcon(FlashMode mode) => switch (mode) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        FlashMode.always => Icons.flash_on,
        FlashMode.torch => Icons.highlight,
      };
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
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
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}

class _QualityBtn extends StatelessWidget {
  const _QualityBtn({required this.isHigh, required this.onTap});
  final bool isHigh;
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
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(
              color: isHigh ? LeicaColors.red : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: isHigh ? LeicaColors.red : LeicaColors.lightGray,
                width: 1,
              ),
            ),
            child: Text(
              isHigh ? 'HQ' : 'STD',
              style: TextStyle(
                color: isHigh ? Colors.white : LeicaColors.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'QUAL',
            style: TextStyle(color: LeicaColors.textDisabled, fontSize: 8, letterSpacing: 1),
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.label, required this.active, required this.onTap});

  final IconData icon;
  final String label;
  final bool active;
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
          Icon(icon, color: active ? LeicaColors.red : LeicaColors.textSecondary, size: 20),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: LeicaColors.textDisabled, fontSize: 8, letterSpacing: 1),
          ),
        ],
      ),
    );
  }
}
