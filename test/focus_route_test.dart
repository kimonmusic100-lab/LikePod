import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/focus_route.dart';

void main() {
  test('direct USB stays claimed while playing until another app takes focus', () {
    expect(
      claimDirectUsb(focusHeld: true, userWantsPlayback: true),
      isTrue,
    );
    expect(
      releaseExclusiveOnFocus('none'),
      isFalse,
    );
    expect(
      releaseExclusiveOnFocus('failed'),
      isFalse,
    );
  });

  test('focus loss and transient loss release the DAC; a duck does not', () {
    for (final change in ['loss', 'lossTransient']) {
      expect(releaseExclusiveOnFocus(change), isTrue);
    }
    expect(releaseExclusiveOnFocus('duck'), isFalse);
    expect(
      claimDirectUsb(focusHeld: false, userWantsPlayback: true),
      isFalse,
    );
    expect(
      claimDirectUsb(focusHeld: true, userWantsPlayback: false),
      isFalse,
    );
  });
}
