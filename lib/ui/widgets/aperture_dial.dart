import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/leica_colors.dart';

/// Circular aperture dial that maps rotation gesture to f-stop values.
class ApertureDial extends StatefulWidget {
  const ApertureDial({
    super.key,
    required this.aperture,
    required this.onChanged,
    required this.maxAperture,
  });

  final double aperture;
  final ValueChanged<double> onChanged;
  final double maxAperture;

  @override
  State<ApertureDial> createState() => _ApertureDialState();
}

class _ApertureDialState extends State<ApertureDial> {
  static const _stops = [1.2, 1.4, 1.7, 2.0, 2.4, 2.8, 3.5, 4.0, 5.6, 8.0, 11.0, 16.0];

  double _startAngle = 0;
  double _currentRotation = 0;

  int get _currentStopIndex => _stops.indexWhere((s) => s >= widget.aperture).clamp(0, _stops.length - 1);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) => _startAngle = math.atan2(d.localPosition.dy - 40, d.localPosition.dx - 40),
      onPanUpdate: (d) {
        final angle = math.atan2(d.localPosition.dy - 40, d.localPosition.dx - 40);
        final delta = angle - _startAngle;
        _startAngle = angle;
        _currentRotation += delta;

        // Each half-rotation = one stop
        if (_currentRotation.abs() > math.pi / _stops.length) {
          final dir = _currentRotation > 0 ? 1 : -1;
          final newIdx = (_currentStopIndex + dir).clamp(0, _stops.length - 1);
          final newAperture = _stops[newIdx];
          if (newAperture >= widget.maxAperture) {
            widget.onChanged(newAperture);
            HapticFeedback.selectionClick();
          }
          _currentRotation = 0;
        }
      },
      child: SizedBox(
        width: 80,
        height: 80,
        child: CustomPaint(
          painter: _ApertureDialPainter(
            aperture: widget.aperture,
            stops: _stops,
            maxAperture: widget.maxAperture,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'f/${widget.aperture % 1 == 0 ? widget.aperture.toInt() : widget.aperture}',
                  style: const TextStyle(
                    color: LeicaColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ApertureDialPainter extends CustomPainter {
  _ApertureDialPainter({required this.aperture, required this.stops, required this.maxAperture});

  final double aperture;
  final List<double> stops;
  final double maxAperture;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    final trackPaint = Paint()
      ..color = LeicaColors.dialTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final activePaint = Paint()
      ..color = LeicaColors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawCircle(center, radius, trackPaint);

    final activeAngle = (stops.indexOf(aperture) / stops.length) * math.pi * 2 - math.pi / 2;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      activeAngle + math.pi / 2,
      false,
      activePaint,
    );

    // Dot at current position
    final dotX = center.dx + radius * math.cos(activeAngle);
    final dotY = center.dy + radius * math.sin(activeAngle);
    canvas.drawCircle(Offset(dotX, dotY), 5, Paint()..color = LeicaColors.red);
  }

  @override
  bool shouldRepaint(_ApertureDialPainter old) => old.aperture != aperture;
}
