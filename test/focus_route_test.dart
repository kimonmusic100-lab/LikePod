import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/focus_route.dart';

void main() {
  test('loss and transient loss pause; gain is not itself a pause', () {
    for (final change in ['loss', 'lossTransient']) {
      expect(pauseForFocusChange(change, inBackground: false), isTrue);
      expect(pauseForFocusChange(change, inBackground: true), isTrue);
    }
    expect(pauseForFocusChange('gain', inBackground: true), isFalse);
    expect(pauseForFocusChange('none', inBackground: true), isFalse);
  });

  test('only a focus-loss pause resumes when focus returns', () {
    final yield = FocusYield();

    yield.noteFocusLost(active: false);
    expect(yield.shouldResume(), isFalse, reason: 'already paused, or cold');

    yield.noteFocusLost(active: true);
    expect(yield.pausedByFocusLoss, isTrue);
    expect(yield.shouldResume(), isTrue);
    expect(yield.shouldResume(), isFalse);

    yield.noteFocusLost(active: true);
    yield.noteUserPause();
    expect(yield.shouldResume(), isFalse);
  });

  test('reclaim only an armed yield after the other app stops', () {
    expect(
      shouldReclaimFocus(
        awaitingReturn: true,
        listening: true,
        otherAppPlaying: false,
      ),
      isTrue,
    );
    expect(
      shouldReclaimFocus(
        awaitingReturn: true,
        listening: true,
        otherAppPlaying: true,
      ),
      isFalse,
    );
    expect(
      shouldReclaimFocus(
        awaitingReturn: false,
        listening: true,
        otherAppPlaying: false,
      ),
      isFalse,
      reason: 'user pause, cold start, or foreground alone',
    );
    expect(
      shouldReclaimFocus(
        awaitingReturn: true,
        listening: false,
        otherAppPlaying: false,
      ),
      isFalse,
    );
  });

  test('a duck pauses only while LikePod is in the background', () {
    expect(pauseForFocusChange('duck', inBackground: true), isTrue);
    expect(pauseForFocusChange('duck', inBackground: false), isFalse);
  });

  test('our own or unreadable player must not pause playback', () {
    const self = 10234;
    expect(
      pauseForForeignPlayback(ownerUid: self, selfUid: self, started: true),
      isFalse,
      reason: 'the track we just started',
    );
    expect(
      pauseForForeignPlayback(ownerUid: null, selfUid: self, started: true),
      isFalse,
      reason: 'hidden uid must not look like another app',
    );
    expect(
      pauseForForeignPlayback(ownerUid: 0, selfUid: self, started: true),
      isFalse,
    );
    expect(
      pauseForForeignPlayback(ownerUid: 10400, selfUid: self, started: false),
      isFalse,
    );
    expect(
      pauseForForeignPlayback(ownerUid: 10400, selfUid: self, started: true),
      isTrue,
    );
  });

  test('a yield resume waits 3.8 seconds, then fades back to unity', () {
    expect(yieldResumeGap, const Duration(milliseconds: 3800));
    expect(yieldFadeDuration, const Duration(milliseconds: 800));
    expect(yieldFadeDuration.inMilliseconds, inInclusiveRange(500, 1000));
    expect(resumeDelay(fromFocusYield: false), Duration.zero);
    expect(resumeDelay(fromFocusYield: true), yieldResumeGap);
    expect(yieldFadeGain(0, 8), 0);
    expect(yieldFadeGain(8, 8), 1);
    expect(yieldFadeGain(4, 8), closeTo(0.5, 0.001));
  });

  test('reclaim waits for another app and not for our own row', () {
    const self = 10234;
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: 10400,
        selfUid: self,
        started: true,
        selfPlaying: false,
        musicActive: true,
      ),
      isTrue,
    );
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: self,
        selfUid: self,
        started: true,
        selfPlaying: true,
        musicActive: true,
      ),
      isFalse,
    );
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: null,
        selfUid: self,
        started: true,
        selfPlaying: true,
        musicActive: true,
      ),
      isFalse,
      reason: 'unreadable row while we are playing is our own track',
    );
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: null,
        selfUid: self,
        started: true,
        selfPlaying: false,
        musicActive: false,
      ),
      isFalse,
      reason: 'stale started row with no music must not pin the yield',
    );
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: null,
        selfUid: self,
        started: true,
        selfPlaying: false,
        musicActive: true,
      ),
      isTrue,
    );
  });

  test('a quiet leftover row from another app does not pin the yield', () {
    const self = 10234;
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: 10400,
        selfUid: self,
        started: true,
        selfPlaying: false,
        musicActive: true,
        quietLongEnough: true,
      ),
      isTrue,
      reason: 'still audible',
    );
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: 10400,
        selfUid: self,
        started: true,
        selfPlaying: false,
        musicActive: false,
        quietLongEnough: false,
      ),
      isTrue,
      reason: 'silence has to hold briefly',
    );
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: 10400,
        selfUid: self,
        started: true,
        selfPlaying: false,
        musicActive: false,
        quietLongEnough: true,
      ),
      isFalse,
      reason: 'Bilibili-class leftover after the stream is free',
    );
    expect(
      playbackBlocksReclaim(
        rows: [(ownerUid: 10400, started: true)],
        selfUid: self,
        selfPlaying: false,
        musicActive: false,
        quietLongEnough: true,
      ),
      isFalse,
    );
    expect(
      playbackBlocksReclaim(
        rows: const [],
        selfUid: self,
        selfPlaying: false,
        musicActive: false,
        callMode: true,
      ),
      isTrue,
      reason: 'a phone call blocks even with no player row',
    );
    expect(
      foreignPlaybackBlocksReclaim(
        ownerUid: 10400,
        selfUid: self,
        started: false,
        selfPlaying: false,
        musicActive: false,
        callMode: true,
      ),
      isTrue,
    );
  });

  test('an explicit paused description beats a started reflection', () {
    expect(
      playbackRowStarted(reflectedStarted: true, describedState: 'paused'),
      isFalse,
    );
    expect(
      playbackRowStarted(reflectedStarted: true, describedState: 'stopped'),
      isFalse,
    );
    expect(
      playbackRowStarted(reflectedStarted: true, describedState: 'idle'),
      isFalse,
    );
    expect(
      playbackRowStarted(reflectedStarted: true, describedState: 'released'),
      isFalse,
    );
    expect(
      playbackRowStarted(reflectedStarted: false, describedState: 'started'),
      isTrue,
    );
    expect(
      playbackRowStarted(reflectedStarted: true, describedState: null),
      isTrue,
    );
    expect(
      playbackRowStarted(reflectedStarted: false, describedState: null),
      isFalse,
    );
    expect(
      playbackRowStarted(reflectedStarted: null, describedState: 'unknown'),
      isFalse,
    );
  });
}
