import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/spectrum_feed.dart';

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

/// Center of the first dot column.
///
/// Columns sit [pitch] apart. The ink runs from the left edge of the first
/// dot to the right edge of the last, and whatever width is left is split
/// evenly. [radius] is the unscaled dot radius (peak dots stay on these centers).
double dotColumnOriginX({
  required double width,
  required int columns,
  required double pitch,
  required double radius,
}) {
  if (columns <= 1) return width / 2;
  final occupied = (columns - 1) * pitch + radius * 2;
  return (width - occupied) / 2 + radius;
}

/// Lit black dots only. Levels come from [SpectrumFeed].
class NowPlayingWave extends StatefulWidget {
  final Color color;

  const NowPlayingWave({super.key, required this.color});

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
      key: const ValueKey('now_playing_wave'),
      height: nowPlayingWaveHeight,
      width: double.infinity,
      child: CustomPaint(
        painter: _DotColumnPainter(
          color: widget.color,
          levels: SpectrumFeed.instance.levels.value,
        ),
      ),
    );
  }
}

class _DotColumnPainter extends CustomPainter {
  final Color color;
  final List<double> levels;

  const _DotColumnPainter({required this.color, required this.levels});

  double _bandAt(double t) {
    if (levels.isEmpty) return 0;
    if (levels.length == 1) return levels.first.clamp(0.0, 1.0);
    final x = t.clamp(0.0, 1.0) * (levels.length - 1);
    final i = x.floor().clamp(0, levels.length - 2);
    final f = x - i;
    final s = f * f * (3 - 2 * f);
    return (levels[i] * (1 - s) + levels[i + 1] * s).clamp(0.0, 1.0);
  }

  /// Lit dots only. Empty cells stay blank. No gray ghosts.
  @override
  void paint(Canvas canvas, Size size) {
    const rows = 8;
    final stepY = (size.height - 4) / rows;
    final radius = (stepY * 0.32).clamp(1.15, 1.7);
    final stepX = math.max(stepY * 1.15, radius * 3.1);
    final cols = math.max(12, ((size.width - 8) / stepX).floor());
    final originX = dotColumnOriginX(
      width: size.width,
      columns: cols,
      pitch: stepX,
      radius: radius,
    );
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

  @override
  bool shouldRepaint(covariant _DotColumnPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.levels != levels;
  }
}
