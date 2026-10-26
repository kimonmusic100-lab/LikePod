/// When LikePod should pause for an audio-focus change.
///
/// Playback uses the system mixer. A full loss or a transient loss always
/// pauses. A duck pauses only in the background, where feed apps take the
/// output with MAY_DUCK. Focus returning never starts playback.
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

/// Focus gain restores readiness only. The user presses play.
bool resumeOnFocusGain() => false;
