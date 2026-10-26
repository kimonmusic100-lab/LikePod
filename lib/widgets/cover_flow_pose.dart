/// Where one Cover Flow card sits for a signed distance from the focused album.
///
/// `delta` 0 is the front-facing center cover. Negative values fold to the
/// left and positive values fold to the right. Distances between 0 and 1
/// interpolate so a cover can turn into the side pose instead of snapping.
class CoverFlowPose {
  final double left;
  final double rotY;
  final double spine;

  const CoverFlowPose(this.left, this.rotY, this.spine);

  static const double sideTilt = 1.25;
  static const double projected = 0.315;
  static const double gap = 6;
  static const double spineStep = 18;

  static CoverFlowPose at({
    required double delta,
    required double cardSize,
    required double centerX,
  }) {
    final centerLeft = centerX - cardSize / 2;
    if (delta.abs() < 1e-6) {
      return CoverFlowPose(centerLeft, 0, 0);
    }

    final sign = delta < 0 ? -1.0 : 1.0;
    final distance = delta.abs();
    final nearestLeft = _foldedLeft(
      sign: sign,
      cardSize: cardSize,
      centerLeft: centerLeft,
    );
    final nearestRot = sign < 0 ? -sideTilt : sideTilt;
    if (distance <= 1) {
      final t = distance;
      return CoverFlowPose(
        centerLeft + (nearestLeft - centerLeft) * t,
        nearestRot * t,
        t,
      );
    }

    final shift = (distance - 1) * spineStep * sign;
    return CoverFlowPose(nearestLeft + shift, nearestRot, 1);
  }

  static double _foldedLeft({
    required double sign,
    required double cardSize,
    required double centerLeft,
  }) {
    final halfVis = cardSize * projected / 2;
    if (sign < 0) {
      final visualRight = centerLeft - gap;
      return visualRight - cardSize / 2 - halfVis;
    }
    final visualLeft = centerLeft + cardSize + gap;
    return visualLeft - cardSize / 2 + halfVis;
  }
}
