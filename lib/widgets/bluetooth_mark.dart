import 'package:flutter/material.dart';

import '../theme/classic_glass.dart';

/// Filled Bluetooth rune (SIG / Material geometry).
///
/// The glyph bounds in the 24dp source are x 5–17.71 and y 2–22, so a
/// status height of 11 keeps the width near 7. Color is the play-mark glass.
class BluetoothMark extends StatelessWidget {
  const BluetoothMark({super.key});

  /// Matches the status play triangle height.
  static const double height = 11;

  /// 12.71 / 20 * [height].
  static const double width = 7;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(width, height),
      painter: _BluetoothMarkPainter(),
    );
  }
}

class _BluetoothMarkPainter extends CustomPainter {
  static final Path _rune = Path()
    ..moveTo(17.71, 7.71)
    ..lineTo(12, 2)
    ..lineTo(11, 2)
    ..lineTo(11, 9.59)
    ..lineTo(6.41, 5)
    ..lineTo(5, 6.41)
    ..lineTo(10.59, 12)
    ..lineTo(5, 17.59)
    ..lineTo(6.41, 19)
    ..lineTo(11, 14.41)
    ..lineTo(11, 22)
    ..lineTo(12, 22)
    ..lineTo(17.71, 16.29)
    ..lineTo(13.41, 12)
    ..close()
    ..moveTo(13, 5.83)
    ..lineTo(14.88, 7.71)
    ..lineTo(13, 9.59)
    ..close()
    ..moveTo(14.88, 16.29)
    ..lineTo(13, 18.17)
    ..lineTo(13, 14.41)
    ..close();

  static final Rect _bounds = Rect.fromLTRB(5, 2, 17.71, 22);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = ClassicGlass.progressFill.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      )
      ..style = PaintingStyle.fill;
    final scale = size.height / _bounds.height;
    canvas.save();
    canvas.translate(
      (size.width - _bounds.width * scale) / 2 - _bounds.left * scale,
      -_bounds.top * scale,
    );
    canvas.scale(scale);
    canvas.drawPath(_rune, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BluetoothMarkPainter oldDelegate) => false;
}
