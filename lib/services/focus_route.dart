/// When LikePod may hold the USB interface exclusively.
///
/// [focusHeld] means no other app has taken focus. A failed or still-pending
/// focus request is still [focusHeld]: lifeme can refuse the request while
/// the DAC is free, and that must not block direct USB. Home does not matter.
/// Only a real loss clears [focusHeld].
bool claimDirectUsb({
  required bool focusHeld,
  required bool userWantsPlayback,
}) {
  return focusHeld && userWantsPlayback;
}

/// Full loss and transient loss release the DAC once the native side has
/// decided another background app took audio. A duck does not: lifeme
/// delivers one during LikePod's own playback, and releasing there closed
/// exclusive USB. Bilibili and Douyin take focus with a real loss.
bool releaseExclusiveOnFocus(String change) {
  switch (change) {
    case 'loss':
    case 'lossTransient':
      return true;
    default:
      return false;
  }
}
