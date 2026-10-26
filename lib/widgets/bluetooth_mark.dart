import 'package:flutter/material.dart';

/// Small Classic-style status mark for Bluetooth output.
class BluetoothMark extends StatelessWidget {
  final Color color;

  const BluetoothMark({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(11, 13),
      painter: _BluetoothMarkPainter(color),
    );
  }
}

class _BluetoothMarkPainter extends CustomPainter {
  final Color color;

  _BluetoothMarkPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
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
  bool shouldRepaint(covariant _BluetoothMarkPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
