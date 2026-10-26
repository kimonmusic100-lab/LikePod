import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/spectrum_feed.dart';
import '../services/wave_style.dart';

/// Height of the band drawn under the cover. It is overlaid, so it does not
/// change the cover's layout slot.
const double nowPlayingWaveHeight = 56;

/// Distance from the bottom of the cover area to the waveform.
///
/// The cover stays centered in the full area. The band sits just under that
/// cover, which leaves a larger gap above the progress bar.
double nowPlayingWaveBottom({
  required double areaHeight,
  required double coverHeight,
}) {
  const gapUnderCover = 8.0;
  const minGapAboveProgress = 22.0;
  final slackBelow = (areaHeight - coverHeight) / 2;
  final underCover = slackBelow - gapUnderCover - nowPlayingWaveHeight;
  if (underCover >= minGapAboveProgress) return underCover;
  final clearOfCover = slackBelow - 4 - nowPlayingWaveHeight;
  if (clearOfCover >= 10) return clearOfCover;
  return minGapAboveProgress;
}

/// The three Now Playing waveforms. Levels come from [SpectrumFeed].
class NowPlayingWave extends StatefulWidget {
  final WaveStyle style;
  final Color color;

  const NowPlayingWave({super.key, required this.style, required this.color});

  @override
  State<NowPlayingWave> createState() => _NowPlayingWaveState();
}

class _NowPlayingWaveState extends State<NowPlayingWave> {
  @override
  void initState() {
    super.initState();
    SpectrumFeed.instance.levels.addListener(_onLevels);
  }

  @override
  void dispose() {
    SpectrumFeed.instance.levels.removeListener(_onLevels);
    super.dispose();
  }

  void _onLevels() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey('now_playing_wave_${widget.style.name}'),
      height: nowPlayingWaveHeight,
      width: double.infinity,
      child: CustomPaint(
        painter: _WavePainter(
          style: widget.style,
          color: widget.color,
          levels: SpectrumFeed.instance.levels.value,
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final WaveStyle style;
  final Color color;
  final List<double> levels;

  const _WavePainter({
    required this.style,
    required this.color,
    required this.levels,
  });

  double _bandAt(double t) {
    if (levels.isEmpty) return 0;
    if (levels.length == 1) return levels.first.clamp(0.0, 1.0);
    final x = t.clamp(0.0, 1.0) * (levels.length - 1);
    final i = x.floor().clamp(0, levels.length - 2);
    final f = x - i;
    final s = f * f * (3 - 2 * f);
    return (levels[i] * (1 - s) + levels[i + 1] * s).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (style) {
      case WaveStyle.mirror:
        _mirror(canvas, size);
      case WaveStyle.dots:
        _dots(canvas, size);
      case WaveStyle.glow:
        _glow(canvas, size);
    }
  }

  /// Capsules mirrored through a center line, using most of the band height.
  void _mirror(Canvas canvas, Size size) {
    const breadth = 3.6;
    const gap = 2.1;
    const slot = breadth + gap;
    final count = math.max(16, ((size.width - 8) / slot).floor());
    final used = count * slot - gap;
    final origin = (size.width - used) / 2;
    final mid = size.height / 2;
    const split = 0.7;
    final reach = math.max(8.0, mid - split);
    canvas.drawLine(
      Offset(origin, mid),
      Offset(origin + used, mid),
      Paint()
        ..color = color.withValues(alpha: 0.2)
        ..strokeWidth = 0.8,
    );
    final paint = Paint()..color = color;
    final radius = Radius.circular(breadth / 2);
    for (var i = 0; i < count; i++) {
      final t = count == 1 ? 0.5 : i / (count - 1);
      final edge = 0.82 + 0.18 * math.sin(t * math.pi);
      final level = (_bandAt(t) * edge).clamp(0.0, 1.0);
      final body = math.max(1.4, reach * level);
      final x = origin + i * slot;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - split - body, breadth, body),
          radius,
        ),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid + split, breadth, body),
          radius,
        ),
        paint,
      );
    }
  }

  /// Lit dots only. Empty cells stay blank.
  void _dots(Canvas canvas, Size size) {
    const rows = 8;
    final stepY = (size.height - 4) / rows;
    final radius = (stepY * 0.32).clamp(1.15, 1.7);
    final stepX = math.max(stepY * 1.15, radius * 3.1);
    final cols = math.max(12, ((size.width - 8) / stepX).floor());
    final usedW = cols * stepX;
    final originX = (size.width - usedW) / 2 + stepX / 2;
    final bottom = size.height - 2 - radius;
    final lit = Paint()..color = color;
    for (var c = 0; c < cols; c++) {
      final t = cols == 1 ? 0.5 : c / (cols - 1);
      final level = _bandAt(t);
      final litCount = (level * rows).round().clamp(0, rows);
      for (var r = 0; r < litCount; r++) {
        final peak = r == litCount - 1;
        canvas.drawCircle(
          Offset(originX + c * stepX, bottom - r * stepY),
          peak ? radius * 1.15 : radius,
          lit,
        );
      }
    }
  }

  /// Narrow dark-gray columns with a soft halo. Denser than the mirror row.
  void _glow(Canvas canvas, Size size) {
    const breadth = 2.0;
    const gap = 1.7;
    const slot = breadth + gap;
    final count = math.max(28, ((size.width - 6) / slot).floor());
    final used = count * slot - gap;
    final origin = (size.width - used) / 2;
    const ink = Color(0xFF525252);
    final glow = Paint()
      ..color = ink.withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.6);
    final core = Paint()..color = ink;
    for (var i = 0; i < count; i++) {
      final t = count == 1 ? 0.5 : i / (count - 1);
      final body = math.max(1.5, (size.height - 2) * _bandAt(t));
      final rect = Rect.fromLTWH(
        origin + i * slot,
        size.height - body,
        breadth,
        body,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(1.2), const Radius.circular(2)),
        glow,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        core,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return oldDelegate.style != style ||
        oldDelegate.color != color ||
        oldDelegate.levels != levels;
  }
}
