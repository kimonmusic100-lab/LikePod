/// When LikePod should pause for an audio-focus change.
///
/// Playback uses the system mixer. A full loss or a transient loss always
/// pauses. A duck pauses only in the background, where feed apps take the
/// output with MAY_DUCK. Transient loss delivers gain when the other app
/// releases (小红书). Permanent loss does not (B站 / 抖音). Reclaim once
/// the music stream is quiet, even if a leftover started row remains.
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

/// Quiet moment after the other app has released audio, before we start.
/// 3.8 seconds, then the fade rises to the current level. Manual play,
/// next, and seek do not wait and do not fade.
const yieldResumeGap = Duration(milliseconds: 3800);

/// Ramp the player from silence to unity after a yield resume.
/// The system music volume is unchanged; unity matches the user's setting.
const yieldFadeDuration = Duration(milliseconds: 800);

/// Linear fade step. [step] is 1-based and [stepCount] is the last step.
double yieldFadeGain(int step, int stepCount) {
  if (stepCount <= 0) return 1;
  final gain = step / stepCount;
  if (gain < 0) return 0;
  if (gain > 1) return 1;
  return gain;
}

/// Manual play has no inserted gap. A focus yield waits [yieldResumeGap].
Duration resumeDelay({required bool fromFocusYield}) {
  return fromFocusYield ? yieldResumeGap : Duration.zero;
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

/// Whether one playback row should count as started.
///
/// The public `toString` wins when it names a state. Reflection on
/// PME110 has reported STARTED for a player that had already paused,
/// which pinned a permanent-loss yield after the other app was closed.
bool playbackRowStarted({bool? reflectedStarted, String? describedState}) {
  switch (describedState?.toLowerCase()) {
    case 'paused':
    case 'stopped':
    case 'idle':
    case 'released':
      return false;
    case 'started':
      return true;
    default:
      return reflectedStarted == true;
  }
}

/// Whether a row should hold an armed yield instead of requesting focus.
///
/// A confirmed other app waits while the music stream is active. After
/// the stream goes quiet, it keeps waiting only until [quietLongEnough]:
/// a leftover started row must not pin the yield once audio is free.
/// An unreadable started row waits only while music is still active.
/// A phone call always waits. Our own uid never blocks.
bool foreignPlaybackBlocksReclaim({
  required int? ownerUid,
  required int selfUid,
  required bool started,
  required bool selfPlaying,
  required bool musicActive,
  bool callMode = false,
  bool quietLongEnough = false,
}) {
  if (callMode) return true;
  if (!started || ownerUid == selfUid) return false;
  final otherApp = ownerUid != null && ownerUid >= 10000;
  if (!musicActive) {
    if (!otherApp) return false;
    return !quietLongEnough;
  }
  if (otherApp) return true;
  if (selfPlaying) return false;
  return true;
}

/// Armed-yield gate across every current playback row.
///
/// A call blocks even when the list is empty. Otherwise one blocking
/// row is enough. Mirrors `PlaybackFocus.blocksReclaim`.
bool playbackBlocksReclaim({
  required List<({int? ownerUid, bool started})> rows,
  required int selfUid,
  required bool selfPlaying,
  required bool musicActive,
  bool callMode = false,
  bool quietLongEnough = false,
}) {
  if (callMode) return true;
  for (final row in rows) {
    if (foreignPlaybackBlocksReclaim(
      ownerUid: row.ownerUid,
      selfUid: selfUid,
      started: row.started,
      selfPlaying: selfPlaying,
      musicActive: musicActive,
      quietLongEnough: quietLongEnough,
    )) {
      return true;
    }
  }
  return false;
}
