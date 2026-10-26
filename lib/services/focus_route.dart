/// When LikePod should pause for an audio-focus change.
///
/// Playback uses the system mixer. A full loss or a transient loss always
/// pauses. A duck pauses only in the background, where feed apps take the
/// output with MAY_DUCK.
bool pauseForFocusChange(String change, {required bool inBackground}) {
  switch (change) {
    case 'loss':
    case 'lossTransient':
      return true;
    case 'duck':
      return inBackground;
    default:
      return false;
  }
}

/// Remembers a pause that happened only because another app took audio.
///
/// A cold launch and a pause the user asked for do not resume when focus
/// comes back. The flag is consumed by [shouldResume].
class FocusYield {
  bool pausedByFocusLoss = false;

  /// [active] is true when LikePod was playing or still intended to play.
  void noteFocusLost({required bool active}) {
    if (active) pausedByFocusLoss = true;
  }

  void noteUserPause() {
    pausedByFocusLoss = false;
  }

  bool shouldResume() {
    final resume = pausedByFocusLoss;
    pausedByFocusLoss = false;
    return resume;
  }
}
