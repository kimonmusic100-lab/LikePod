import 'dart:math' as math;

/// Now Playing waveform. The shape follows the playhead. A live FFT would
/// need a capture permission and is often silent for this player's own
/// stream, so the bands are synthesized from the playhead and a song seed.
enum WaveStyle {
  bars('经典柱状'),
  mirror('镜像柱'),
  scope('示波曲线'),
  mountain('山形填充'),
  radial('环形频谱'),
  dots('点阵柱'),
  glow('柔光柱'),
  scroll('横向滚动'),
  reflect('湖面倒影'),
  lines('极简细线');

  const WaveStyle(this.label);

  final String label;

  static const fallback = WaveStyle.bars;

  static WaveStyle fromName(String? name) {
    for (final style in WaveStyle.values) {
      if (style.name == name) return style;
    }
    return fallback;
  }
}

const int waveBandCount = 12;
const int waveSampleCount = 48;

int waveSeed(String title) {
  var hash = 17;
  for (final unit in title.codeUnits) {
    hash = (hash * 33 + unit) & 0x7fffffff;
  }
  return hash;
}

/// Band height in 0..1. [phase] advances with the playhead.
double waveLevel(int index, int count, double phase, int seed) {
  if (count <= 0) return 0;
  final i = index.clamp(0, count - 1);
  final tilt = 0.55 + 0.45 * math.sin(phase * 0.31 + seed * 0.01);
  final low = math.sin(phase * (0.62 + i * 0.17) + seed);
  final high = math.sin(phase * (1.15 + i * 0.09) + i * 0.7 + seed * 0.2);
  final mix = 0.5 + 0.5 * (0.65 * low + 0.35 * high);
  final level = (0.12 + 0.88 * mix * tilt).clamp(0.0, 1.0);
  return level;
}

List<double> waveLevels({
  required double phase,
  required int seed,
  int count = waveBandCount,
}) {
  return [for (var i = 0; i < count; i++) waveLevel(i, count, phase, seed)];
}

/// One sample of the line styles, in -1..1.
double waveSample(int index, int count, double phase, int seed) {
  if (count <= 1) return 0;
  final t = index / (count - 1);
  final wobble = (seed % 9) * 0.2;
  final a = math.sin((t * 5.5 + phase * 0.33) * math.pi + wobble);
  final b = math.sin((t * 11 + phase * 0.21) * math.pi + wobble * 1.4);
  return (0.64 * a + 0.36 * b).clamp(-1.0, 1.0);
}

List<double> waveSamples({
  required double phase,
  required int seed,
  int count = waveSampleCount,
}) {
  return [for (var i = 0; i < count; i++) waveSample(i, count, phase, seed)];
}
