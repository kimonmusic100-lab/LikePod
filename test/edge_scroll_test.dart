import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/widgets/edge_scroll.dart';

void main() {
  const item = 32.0;
  const viewport = 160.0;

  double offset({
    required int index,
    required int? previous,
    required double current,
    double max = 10000,
  }) {
    return EdgeScroll.targetOffset(
      index: index,
      previousIndex: previous,
      itemHeight: item,
      viewport: viewport,
      currentOffset: current,
      maxOffset: max,
    );
  }

  test('highlight walks inside the viewport before the list moves', () {
    expect(offset(index: 0, previous: null, current: 0), 0);
    expect(offset(index: 3, previous: 2, current: 0), 0);
    expect(offset(index: 4, previous: 5, current: 32), 32);
  });

  test('scrolling down pins the highlight to the bottom row', () {
    expect(offset(index: 5, previous: 4, current: 0), 32);
    expect(offset(index: 6, previous: 5, current: 32), 64);
  });

  test('scrolling up pins the highlight to the top row', () {
    expect(offset(index: 0, previous: 1, current: 32), 0);
  });

  test('offset stays inside the scroll range', () {
    expect(offset(index: 8, previous: 7, current: 64, max: 40), 40);
    expect(
      EdgeScroll.targetOffset(
        index: 0,
        previousIndex: null,
        itemHeight: 0,
        viewport: viewport,
        currentOffset: 12,
        maxOffset: 40,
      ),
      0,
    );
  });
}
