/// Now Playing waveform. Only the three styles the user kept.
enum WaveStyle {
  mirror('镜像柱'),
  dots('点阵柱'),
  glow('柔光柱');

  const WaveStyle(this.label);

  final String label;

  /// Fresh installs, and any retired style name, open on the mirrored bars.
  static const fallback = WaveStyle.mirror;

  static WaveStyle fromName(String? name) {
    for (final style in WaveStyle.values) {
      if (style.name == name) return style;
    }
    return fallback;
  }
}

/// Bands delivered by the playback visualizer.
const int spectrumBandCount = 24;

/// One capture frame, eased so rises are quicker than falls, then blurred
/// across neighbors so a single bin does not flicker.
List<double> smoothSpectrum(List<double> previous, List<double> target) {
  final count = spectrumBandCount;
  final stepped = List<double>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    final from = i < previous.length ? previous[i] : 0.0;
    final to = (i < target.length ? target[i] : 0.0).clamp(0.0, 1.0);
    final rate = to > from ? 0.62 : 0.28;
    stepped[i] = from + (to - from) * rate;
  }
  final blurred = List<double>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    final left = stepped[i == 0 ? 0 : i - 1];
    final mid = stepped[i];
    final right = stepped[i == count - 1 ? i : i + 1];
    blurred[i] = (left * 0.18 + mid * 0.64 + right * 0.18).clamp(0.0, 1.0);
  }
  return blurred;
}
