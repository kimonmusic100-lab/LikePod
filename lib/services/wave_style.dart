// Band count and easing for the Now Playing dot columns.
// The visualizer is only 点阵柱. There is no style picker.

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
