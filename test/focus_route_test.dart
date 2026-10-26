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
}
