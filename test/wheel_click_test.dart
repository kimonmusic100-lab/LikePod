import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/sound_service.dart';

void main() {
  test('wheel clicks stay under the song and loud enough to hear', () {
    // 0.10 (−20 dB) was audible on PME110 but too soft. 0.26 is about
    // −12 dB under full scale: still quieter than the music.
    expect(SoundService.clickVolume, closeTo(0.26, 0.001));
    expect(SoundService.clickVolume, greaterThan(0.20));
    expect(SoundService.clickVolume, lessThan(0.35));
  });
}
