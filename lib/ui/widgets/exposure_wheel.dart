import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/leica_colors.dart';

/// Horizontal scroll wheel for shutter speed or ISO selection.
class ExposureWheel extends StatefulWidget {
  const ExposureWheel({
    super.key,
    required this.values,
    required this.selectedIndex,
    required this.onChanged,
    required this.label,
  });

  final List<String> values;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  State<ExposureWheel> createState() => _ExposureWheelState();
}

class _ExposureWheelState extends State<ExposureWheel> {
  late final ScrollController _scroll;
  static const double _itemWidth = 52.0;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(initialScrollOffset: widget.selectedIndex * _itemWidth);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            color: LeicaColors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final sidepad = ((constraints.maxWidth - _itemWidth) / 2).clamp(0.0, double.infinity);
            return SizedBox(
              height: 40,
              child: NotificationListener<ScrollEndNotification>(
                onNotification: (n) {
                  final idx = (_scroll.offset / _itemWidth).round().clamp(0, widget.values.length - 1);
                  if (idx != widget.selectedIndex) {
                    widget.onChanged(idx);
                    HapticFeedback.selectionClick();
                  }
                  return true;
                },
                child: ListView.builder(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: sidepad),
                  itemCount: widget.values.length,
                  itemExtent: _itemWidth,
                  itemBuilder: (ctx, i) {
                    final isSelected = i == widget.selectedIndex;
                    return Center(
                      child: Text(
                        widget.values[i],
                        style: TextStyle(
                          color: isSelected ? LeicaColors.textPrimary : LeicaColors.textDisabled,
                          fontSize: isSelected ? 14 : 11,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                          letterSpacing: 0.3,
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
        // Tick mark
        Container(width: 1, height: 8, color: LeicaColors.red),
      ],
    );
  }
}
