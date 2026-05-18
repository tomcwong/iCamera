import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/leica_colors.dart';
import '../../features/lens_simulation/lens_profile.dart';

class LensSelector extends StatelessWidget {
  const LensSelector({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LensProfile selected;
  final ValueChanged<LensProfile> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: LensProfile.values.map((lens) {
        final isSelected = lens == selected;
        return GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onSelected(lens);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  style: TextStyle(
                    color: isSelected ? lens.uiColor : LeicaColors.textDisabled,
                    fontSize: isSelected ? 16 : 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                  child: Text(lens.shortName),
                ),
                const SizedBox(height: 3),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: isSelected ? 20 : 0,
                  height: 2,
                  decoration: BoxDecoration(
                    color: lens.uiColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                Text(
                  lens.apertureSpec,
                  style: TextStyle(
                    color: isSelected ? LeicaColors.textSecondary : LeicaColors.textDisabled,
                    fontSize: 9,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
