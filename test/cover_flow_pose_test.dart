import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/widgets/cover_flow_pose.dart';

void main() {
  const card = 100.0;
  const centerX = 200.0;

  CoverFlowPose pose(double delta) {
    return CoverFlowPose.at(delta: delta, cardSize: card, centerX: centerX);
  }

  test('center cover is front-facing', () {
    final center = pose(0);
    expect(center.left, centerX - card / 2);
    expect(center.rotY, 0);
    expect(center.spine, 0);
  });

  test('a half step turns halfway into the folded pose', () {
    final center = pose(0);
    final folded = pose(-1);
    final mid = pose(-0.5);

    expect(folded.rotY, -CoverFlowPose.sideTilt);
    expect(folded.left, lessThan(center.left));
    expect(mid.rotY, closeTo(-CoverFlowPose.sideTilt / 2, 0.0001));
    expect(mid.left, closeTo((center.left + folded.left) / 2, 0.0001));
    expect(mid.spine, closeTo(0.5, 0.0001));
  });

  test('covers past the first neighbor keep the fold and step sideways', () {
    final nearest = pose(-1);
    final further = pose(-2);
    final right = pose(1);

    expect(further.rotY, nearest.rotY);
    expect(further.left, closeTo(nearest.left - CoverFlowPose.spineStep, 0.0001));
    expect(further.spine, 1);
    expect(right.rotY, CoverFlowPose.sideTilt);
    expect(right.left, greaterThan(pose(0).left));
  });
}
