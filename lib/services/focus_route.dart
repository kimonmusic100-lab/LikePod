/// When LikePod should pause for an audio-focus change.
///
/// Playback uses the system mixer. A full loss or a transient loss always
/// pauses. A duck pauses only in the background, where feed apps take the
/// output with MAY_DUCK. Transient loss delivers gain when the other app
/// releases (小红书). Permanent loss does not, so Android reclaims focus
/// once no other app is still playing (B站 / 抖音).
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

/// Reclaim focus only for an armed yield, and never while the interrupter
/// is still playing. Foreground return is not a reason by itself.
bool shouldReclaimFocus({
  required bool awaitingReturn,
  required bool listening,
  required bool otherAppPlaying,
}) {
  return listening && awaitingReturn && !otherAppPlaying;
}

/// Whether one playback-configuration row should pause LikePod.
///
/// Only a started player owned by a different app. Our own player, a
/// paused row, and a row whose uid cannot be read must not: vc35 treated
/// those as "someone else", so starting a song paused it, the reclaim
/// started it again, and the loop force-closed the process.
/// Mirrors `PlaybackFocus` (uid below 10000 is not an app uid).
bool pauseForForeignPlayback({
  required int? ownerUid,
  required int selfUid,
  required bool started,
}) {
  if (!started || ownerUid == null || ownerUid == selfUid) return false;
  if (ownerUid < 10000) return false;
  return true;
}

/// Whether a row should hold an armed yield instead of requesting focus.
///
/// A confirmed other app always waits. An unreadable started row waits
/// only while we are already paused and music is still active, so a stale
/// row for our own track cannot pin the yield open.
bool foreignPlaybackBlocksReclaim({
  required int? ownerUid,
  required int selfUid,
  required bool started,
  required bool selfPlaying,
  required bool musicActive,
}) {
  if (!started || ownerUid == selfUid) return false;
  if (ownerUid != null && ownerUid >= 10000) return true;
  if (selfPlaying) return false;
  return musicActive;
}
