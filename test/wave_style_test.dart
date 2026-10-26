import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/wave_style.dart';

void main() {
  test('playhead levels stay in range and change with phase', () {
    final early = waveLevels(phase: 0.4, seed: 19);
    final later = waveLevels(phase: 2.2, seed: 19);
    expect(early, hasLength(waveBandCount));
    expect(later, hasLength(waveBandCount));
    for (final level in early) {
      expect(level, inInclusiveRange(0, 1));
    }
    expect(early, isNot(equals(later)));
    final samples = waveSamples(phase: 1.1, seed: 19);
    expect(samples, hasLength(waveSampleCount));
    for (final sample in samples) {
      expect(sample, inInclusiveRange(-1, 1));
    }
  });

  test('style names round-trip and unknown names use classic bars', () {
    expect(WaveStyle.values, hasLength(10));
    expect(WaveStyle.fromName('radial'), WaveStyle.radial);
    expect(WaveStyle.fromName('lines').label, '极简细线');
    expect(WaveStyle.fromName(null), WaveStyle.bars);
    expect(WaveStyle.fromName('nope'), WaveStyle.bars);
    expect(waveSeed('晴天'), isNot(waveSeed('七里香')));
  });
}
