/// Drops wheel ticks that arrive before the previous one can be heard.
///
/// A fast flick used to queue a SoundPool play per pointer event, so the
/// clicks piled up past the menu steps. Center and menu clicks do not use
/// this gate.
class WheelTickGate {
  WheelTickGate({this.gap = const Duration(milliseconds: 80)});

  final Duration gap;
  int? _lastMs;

  bool allow(int nowMs) {
    final last = _lastMs;
    if (last != null && nowMs - last < gap.inMilliseconds) return false;
    _lastMs = nowMs;
    return true;
  }
}
