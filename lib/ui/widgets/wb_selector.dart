import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/leica_colors.dart';
import '../../features/camera/models/capture_settings.dart';

class WbSelector extends StatelessWidget {
  const WbSelector({
    super.key,
    required this.selectedKelvin,
    required this.onSelected,
  });

  final int selectedKelvin;
  final ValueChanged<int> onSelected;

  static const _accent = Color(0xFF64B5F6);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'WHITE BALANCE',
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
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: CaptureSettings.wbPresets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final kelvin = CaptureSettings.wbPresets[i];
              final label = CaptureSettings.wbLabels[i];
              final isSelected = kelvin == selectedKelvin;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onSelected(kelvin);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected ? _accent.withValues(alpha: 0.15) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isSelected ? _accent : LeicaColors.midGray,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      color: isSelected ? _accent : LeicaColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
