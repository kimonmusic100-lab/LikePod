import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/wave_style.dart';

/// Dedicated band under the cover. The cover's own frame is unchanged.
class NowPlayingWave extends StatefulWidget {
  final WaveStyle style;
  final bool playing;
  final int positionSeconds;
  final String title;
  final Color color;

  const NowPlayingWave({
    super.key,
    required this.style,
    required this.playing,
    required this.positionSeconds,
    required this.title,
    required this.color,
  });

  @override
  State<NowPlayingWave> createState() => _NowPlayingWaveState();
}

class _NowPlayingWaveState extends State<NowPlayingWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tick;

  @override
  void initState() {
    super.initState();
    _tick = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    _sync();
  }

  @override
  void didUpdateWidget(covariant NowPlayingWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.playing) {
      if (!_tick.isAnimating) _tick.repeat();
    } else {
      _tick.stop();
    }
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  double _phase(double tick) {
    final head = widget.positionSeconds * 0.73;
    final motion = widget.playing ? tick * 6.4 : 0.0;
    return head + motion + 1.15;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey('now_playing_wave_${widget.style.name}'),
      height: 40,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _tick,
        builder: (context, _) {
          final phase = _phase(_tick.value);
          final seed = waveSeed(widget.title);
          return CustomPaint(
            painter: _WavePainter(
              style: widget.style,
              color: widget.color,
              levels: waveLevels(phase: phase, seed: seed),
              samples: waveSamples(phase: phase, seed: seed),
            ),
          );
        },
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final WaveStyle style;
  final Color color;
  final List<double> levels;
  final List<double> samples;

  const _WavePainter({
    required this.style,
    required this.color,
    required this.levels,
    required this.samples,
  });

  @override
  void paint(Canvas canvas, Size size) {
    switch (style) {
      case WaveStyle.bars:
        _bars(canvas, size, fromCenter: false, reflect: false);
      case WaveStyle.mirror:
        _bars(canvas, size, fromCenter: true, reflect: false);
      case WaveStyle.reflect:
        _bars(canvas, size, fromCenter: false, reflect: true);
      case WaveStyle.dots:
        _dots(canvas, size);
      case WaveStyle.glow:
        _glow(canvas, size);
      case WaveStyle.lines:
        _lines(canvas, size);
      case WaveStyle.scope:
        _line(canvas, size, filled: false, scrolling: false);
      case WaveStyle.mountain:
        _line(canvas, size, filled: true, scrolling: false);
      case WaveStyle.scroll:
        _line(canvas, size, filled: false, scrolling: true);
      case WaveStyle.radial:
        _radial(canvas, size);
    }
  }

  void _bars(
    Canvas canvas,
    Size size, {
    required bool fromCenter,
    required bool reflect,
  }) {
    final count = levels.length;
    final gap = size.width * 0.012;
    final slot = size.width / count;
    final breadth = math.max(1.0, slot - gap);
    final paint = Paint()..color = color;
    for (var i = 0; i < count; i++) {
      final x = slot * i + (slot - breadth) / 2;
      if (reflect) {
        final body = (size.height * 0.46) * levels[i];
        final top = size.height * 0.48 - body;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, top, breadth, body),
            const Radius.circular(1),
          ),
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, size.height * 0.52, breadth, body * 0.72),
            const Radius.circular(1),
          ),
          Paint()..color = color.withValues(alpha: 0.28),
        );
      } else if (fromCenter) {
        final body = (size.height * 0.46) * levels[i];
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, size.height / 2 - body, breadth, body * 2),
            const Radius.circular(1),
          ),
          paint,
        );
      } else {
        final body = (size.height - 1) * levels[i];
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, size.height - body, breadth, body),
            const Radius.circular(1.2),
          ),
          paint,
        );
      }
    }
  }

  void _dots(Canvas canvas, Size size) {
    final count = levels.length;
    final slot = size.width / count;
    final paint = Paint()..color = color;
    const step = 4.2;
    for (var i = 0; i < count; i++) {
      final cx = slot * i + slot / 2;
      final dots = math.max(1, (levels[i] * (size.height / step)).floor());
      for (var d = 0; d < dots; d++) {
        canvas.drawCircle(Offset(cx, size.height - 2 - d * step), 1.15, paint);
      }
    }
  }

  void _glow(Canvas canvas, Size size) {
    final count = levels.length;
    final slot = size.width / count;
    final breadth = math.max(2.0, slot * 0.45);
    final glow = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
    final core = Paint()..color = color;
    for (var i = 0; i < count; i++) {
      final body = (size.height - 2) * levels[i];
      final rect = Rect.fromLTWH(
        slot * i + (slot - breadth) / 2,
        size.height - body,
        breadth,
        body,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(1.5), const Radius.circular(3)),
        glow,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        core,
      );
    }
  }

  void _lines(Canvas canvas, Size size) {
    final count = levels.length;
    final slot = size.width / count;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final x = slot * i + slot / 2;
      final body = math.max(2.0, (size.height - 4) * levels[i]);
      canvas.drawLine(
        Offset(x, size.height - 1),
        Offset(x, size.height - 1 - body),
        paint,
      );
    }
  }

  void _line(
    Canvas canvas,
    Size size, {
    required bool filled,
    required bool scrolling,
  }) {
    if (samples.length < 2) return;
    final path = Path();
    final mid = size.height / 2;
    for (var i = 0; i < samples.length; i++) {
      final x = size.width * i / (samples.length - 1);
      final y = scrolling
          ? mid - samples[i] * (size.height * 0.38)
          : mid - samples[i] * (size.height * 0.42);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (scrolling) {
      final trace = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final ghost = Paint()
        ..color = color.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round;
      canvas.drawLine(
        Offset(0, mid),
        Offset(size.width, mid),
        Paint()
          ..color = color.withValues(alpha: 0.22)
          ..strokeWidth = 0.7,
      );
      canvas.save();
      canvas.translate(-8, 0);
      canvas.drawPath(path, ghost);
      canvas.restore();
      canvas.drawPath(path, trace);
      return;
    }
    if (filled) {
      final fill = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.88));
      return;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
  }

  void _radial(Canvas canvas, Size size) {
    final count = levels.length;
    final center = Offset(size.width / 2, size.height - 1);
    final radius = math.min(size.width * 0.42, size.height - 2);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final angle = math.pi + (math.pi * (i + 0.5) / count);
      final inner = radius * (1 - 0.62 * levels[i]);
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(center + dir * inner, center + dir * radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return oldDelegate.style != style ||
        oldDelegate.color != color ||
        oldDelegate.levels != levels ||
        oldDelegate.samples != samples;
  }
}
