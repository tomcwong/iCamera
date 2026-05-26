import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/leica_colors.dart';
import '../../features/color_science/leica_looks.dart';

class LookSelector extends StatelessWidget {
  const LookSelector({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LeicaLook selected;
  final ValueChanged<LeicaLook> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 16),
              itemCount: LeicaLook.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
          final look = LeicaLook.values[i];
          final isSelected = look == selected;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onSelected(look);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected ? look.accentColor.withValues(alpha: 0.18) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isSelected ? look.accentColor : LeicaColors.midGray,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Text(
                look.displayName.toUpperCase(),
                style: TextStyle(
                  color: isSelected ? look.accentColor : LeicaColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.8,
                ),
              ),
            ),
          );
              },
            ),
          ),
        ],
      ),
    );
  }
}
