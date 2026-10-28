import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/spectrum_feed.dart';
import 'package:likepod/services/wave_style.dart';
import 'package:likepod/widgets/lcd_screen.dart';
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

  test('quieter musical bands rise and silence stays empty', () {
    final bassOnly = List<double>.filled(spectrumBandCount, 0);
    bassOnly[1] = 1;
    final bass = evenOutSpectrum(bassOnly);
    expect(bass[1], closeTo(1, 0.001));
    expect(bass.where((level) => level > 0), hasLength(1));

    final sloped = List<double>.generate(spectrumBandCount, (i) {
      if (i >= 18) return 0.0;
      return 1 - i / 28;
    });
    final even = evenOutSpectrum(sloped);
    expect(even[0], greaterThan(0.95));
    expect(even[12], greaterThan(sloped[12]));
    expect(even[12] - sloped[12], lessThan(0.10));
    expect(even[12], lessThan(even[0]));
    expect(even[20], 0);
    expect(even[23], 0);
    for (var i = 1; i < 18; i++) {
      expect(even[i], lessThanOrEqualTo(even[i - 1] + 1e-9));
    }
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

  test('the tilted cover meets the first dot column', () {
    const leftInset = 22.0;
    const rightInset = 12.0;
    const bandInset = 2.0;
    const waveSide = (leftInset + rightInset) / 2 + bandInset;
    for (final width in [280.0, 340.0, 390.0, 460.0]) {
      final waveWidth = width - waveSide * 2;
      final coverWidth = width / 2 + 18 - leftInset - 16;
      final dotsLeft = waveSide + waveformLeadingEdge(width: waveWidth);
      final blockLeft = dotsLeft - coverArtLeadingOffset(coverWidth);
      expect(
        blockLeft + coverArtLeadingOffset(coverWidth),
        closeTo(dotsLeft, 0.001),
      );
      expect(blockLeft, greaterThan(leftInset));
      expect(blockLeft + coverWidth, lessThan(width - rightInset));
    }
    expect(nowPlayingBlockDrop, greaterThan(6));
    expect(nowPlayingBlockDrop, lessThan(20));
  });

  test('a live level paints at least one dot', () {
    expect(litDotCount(0), 0);
    expect(litDotCount(0.02), 0);
    expect(litDotCount(0.05), 1);
    expect(litDotCount(0.2), 2);
    expect(litDotCount(1), 8);
  });

  test('a playback event does not restart a flat-check', () {
    expect(
      spectrumWatchSettled(
        sameSession: true,
        watchPending: true,
        watchPrompts: false,
        prompt: false,
        promptedThisVisit: false,
      ),
      isTrue,
    );
    expect(
      spectrumWatchSettled(
        sameSession: true,
        watchPending: true,
        watchPrompts: false,
        prompt: true,
        promptedThisVisit: false,
      ),
      isFalse,
    );
    expect(
      spectrumWatchSettled(
        sameSession: true,
        watchPending: true,
        watchPrompts: true,
        prompt: false,
        promptedThisVisit: true,
      ),
      isTrue,
    );
    expect(
      spectrumWatchSettled(
        sameSession: true,
        watchPending: false,
        watchPrompts: false,
        prompt: false,
        promptedThisVisit: false,
      ),
      isTrue,
    );
    expect(
      spectrumWatchSettled(
        sameSession: true,
        watchPending: false,
        watchPrompts: false,
        prompt: true,
        promptedThisVisit: false,
      ),
      isFalse,
    );
    expect(
      spectrumWatchSettled(
        sameSession: true,
        watchPending: false,
        watchPrompts: true,
        prompt: true,
        promptedThisVisit: true,
      ),
      isTrue,
    );
    expect(
      spectrumWatchSettled(
        sameSession: false,
        watchPending: true,
        watchPrompts: true,
        prompt: true,
        promptedThisVisit: true,
      ),
      isFalse,
    );
  });

  test('Now Playing keeps the flat prompt armed until menu leaves', () {
    final feed = SpectrumFeed.instance;
    feed.disarmFlatPrompt();
    expect(feed.debugPromptArmed, isFalse);
    feed.armFlatPrompt();
    expect(feed.debugPromptArmed, isTrue);
    feed.armFlatPrompt();
    expect(feed.debugPromptArmed, isTrue);
    feed.disarmFlatPrompt();
    expect(feed.debugPromptArmed, isFalse);
  });

  test('the waveform sits under the cover and clear of the progress bar', () {
    final roomy = nowPlayingWaveBottom(areaHeight: 360, coverHeight: 140);
    expect(roomy, greaterThanOrEqualTo(22));
    final tight = nowPlayingWaveBottom(areaHeight: 140, coverHeight: 100);
    expect(tight, greaterThanOrEqualTo(10));
  });
}
