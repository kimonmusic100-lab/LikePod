import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/focus_route.dart';

void main() {
  test('loss and transient loss pause; focus gain does not resume', () {
    for (final change in ['loss', 'lossTransient']) {
      expect(pauseForFocusChange(change, inBackground: false), isTrue);
      expect(pauseForFocusChange(change, inBackground: true), isTrue);
    }
    expect(resumeOnFocusGain(), isFalse);
    expect(pauseForFocusChange('gain', inBackground: true), isFalse);
    expect(pauseForFocusChange('none', inBackground: true), isFalse);
  });

  test('a duck pauses only while LikePod is in the background', () {
    expect(pauseForFocusChange('duck', inBackground: true), isTrue);
    expect(pauseForFocusChange('duck', inBackground: false), isFalse);
  });
}
