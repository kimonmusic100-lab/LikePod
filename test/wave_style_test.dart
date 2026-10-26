import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/spectrum_feed.dart';
import 'package:likepod/services/wave_style.dart';
import 'package:likepod/widgets/now_playing_wave.dart';

void main() {
  test('a flat capture is not treated as live audio', () {
    expect(
      spectrumLooksLive(List<double>.filled(spectrumBandCount, 0)),
      isFalse,
    );
    expect(
      spectrumLooksLive(List<double>.filled(spectrumBandCount, 0.02)),
      isFalse,
    );
    final hit = List<double>.filled(spectrumBandCount, 0);
    hit[4] = 0.2;
    expect(spectrumLooksLive(hit), isTrue);
  });

  test('spectrum easing rises faster than it falls', () {
    final quiet = List<double>.filled(spectrumBandCount, 0);
    final hit = List<double>.filled(spectrumBandCount, 0);
    hit[12] = 1;
    final risen = smoothSpectrum(quiet, hit);
    expect(risen[12], greaterThan(0.35));
    expect(risen[12], lessThan(0.85));
    expect(risen[0], lessThan(0.08));

    final loud = List<double>.filled(spectrumBandCount, 1);
    final fallen = smoothSpectrum(loud, quiet);
    expect(fallen[12], greaterThan(0.6));
    expect(fallen[12], lessThan(0.9));
    expect(fallen[12], greaterThan(1 - risen[12]));
  });

  test('dot columns split leftover width evenly', () {
    const pitch = 7.475;
    const radius = 1.7;
    for (final width in [180.0, 240.0, 320.5, 411.0]) {
      final columns = math.max(12, ((width - 8) / pitch).floor());
      final origin = dotColumnOriginX(
        width: width,
        columns: columns,
        pitch: pitch,
        radius: radius,
      );
      final last = origin + (columns - 1) * pitch;
      final left = origin - radius;
      final right = width - (last + radius);
      expect(left, closeTo(right, 0.001));
      expect(left, greaterThanOrEqualTo(0));
    }
  });

  test('the waveform sits under the cover and clear of the progress bar', () {
    final roomy = nowPlayingWaveBottom(areaHeight: 360, coverHeight: 140);
    expect(roomy, greaterThanOrEqualTo(22));
    final tight = nowPlayingWaveBottom(areaHeight: 140, coverHeight: 100);
    expect(tight, greaterThanOrEqualTo(10));
  });
}
