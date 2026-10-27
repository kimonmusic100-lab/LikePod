import 'dart:math' as math;

// Band count and easing for the Now Playing dot columns.
// The visualizer is only 点阵柱. There is no style picker.

/// Bands delivered by the playback visualizer.
const int spectrumBandCount = 24;

/// Slightly raises quieter bands that already have energy.
///
/// The exponent stays close to 1. A stronger lift pulled high-frequency
/// columns up to the bass peak and filled the band.
List<double> evenOutSpectrum(List<double> levels) {
  const gate = 0.05;
  const gamma = 0.90;
  var peak = 0.0;
  for (final level in levels) {
    if (level > peak) peak = level;
  }
  if (peak < gate) return List<double>.filled(levels.length, 0);
  if (peak < 0.08) {
    return [
      for (final level in levels) level < gate ? 0.0 : level.clamp(0.0, 1.0),
    ];
  }
  return [
    for (final level in levels)
      if (level < gate)
        0.0
      else
        (peak * math.pow(level / peak, gamma)).clamp(0.0, 1.0),
  ];
}

/// One capture frame, eased so rises are quicker than falls, then blurred
/// across neighbors so a single bin does not flicker.
List<double> smoothSpectrum(List<double> previous, List<double> target) {
  final count = spectrumBandCount;
  final incoming = List<double>.filled(count, 0);
  for (var i = 0; i < count && i < target.length; i++) {
    incoming[i] = target[i].clamp(0.0, 1.0);
  }
  final balanced = evenOutSpectrum(incoming);
  final stepped = List<double>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    final from = i < previous.length ? previous[i] : 0.0;
    final to = balanced[i];
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
