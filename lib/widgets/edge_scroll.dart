/// Classic click-wheel lists keep the blue bar on a screen edge.
///
/// Scrolling down walks the highlight to the bottom visible row, then the
/// rows move underneath it. Scrolling up walks it to the top row, then the
/// list moves. The bar is not locked to the middle of the screen.
class EdgeScroll {
  static double targetOffset({
    required int index,
    required int? previousIndex,
    required double itemHeight,
    required double viewport,
    required double currentOffset,
    required double maxOffset,
  }) {
    if (itemHeight <= 0 || viewport <= 0) return 0;
    final visible = (viewport / itemHeight).floor().clamp(1, 1000000);
    final delta = previousIndex == null ? 0 : index - previousIndex;
    final first = currentOffset <= 0 ? 0 : (currentOffset / itemHeight).floor();
    final last = first + visible - 1;

    var target = currentOffset;
    if (delta > 0) {
      if (index > last) {
        target = (index - visible + 1) * itemHeight;
      }
    } else if (delta < 0) {
      if (index < first) {
        target = index * itemHeight;
      }
    } else if (index < first) {
      target = index * itemHeight;
    } else if (index > last) {
      target = (index - visible + 1) * itemHeight;
    }

    final upper = maxOffset < 0 ? 0.0 : maxOffset;
    if (target < 0) return 0;
    if (target > upper) return upper;
    return target;
  }
}
