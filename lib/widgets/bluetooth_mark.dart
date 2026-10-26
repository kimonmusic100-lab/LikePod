import 'package:flutter/material.dart';

import '../theme/classic_glass.dart';

/// Small Classic status rune. Stroke uses the same glass as the status
/// play / pause mark ([ClassicGlass.progressFill]), not Material blue.
class BluetoothMark extends StatelessWidget {
  const BluetoothMark({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(11, 13),
      painter: _BluetoothMarkPainter(),
    );
  }
}

class _BluetoothMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = ClassicGlass.progressFill.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final midX = size.width / 2;
    final top = 0.5;
    final bottom = size.height - 0.5;
    final midY = size.height / 2;
    final path = Path()
      ..moveTo(midX, top)
      ..lineTo(midX, bottom)
      ..moveTo(midX, top)
      ..lineTo(size.width - 0.6, midY * 0.72)
      ..lineTo(0.8, midY + (midY - midY * 0.72) * 0.15)
      ..moveTo(midX, bottom)
      ..lineTo(size.width - 0.6, midY + (bottom - midY) * 0.28)
      ..lineTo(0.8, midY * 0.86);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BluetoothMarkPainter oldDelegate) => false;
}
