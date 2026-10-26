import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/sound_service.dart';

void main() {
  test('wheel clicks stay quiet but above the old noise floor', () {
    // 0.016 (−36 dB) on the sonification stream was inaudible after the
    // exclusive USB mix was removed. 0.10 (−20 dB) on the music stream is
    // still well under a full-scale track.
    expect(SoundService.clickVolume, closeTo(0.10, 0.001));
    expect(SoundService.clickVolume, greaterThan(0.016));
    expect(SoundService.clickVolume, lessThan(0.25));
  });
}
