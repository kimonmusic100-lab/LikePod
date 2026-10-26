import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/wheel_tick.dart';

void main() {
  test('fast ticks collapse to one audible click per gap', () {
    final gate = WheelTickGate(gap: const Duration(milliseconds: 80));
    expect(gate.allow(0), isTrue);
    expect(gate.allow(16), isFalse);
    expect(gate.allow(40), isFalse);
    expect(gate.allow(79), isFalse);
    expect(gate.allow(80), isTrue);
    expect(gate.allow(81), isFalse);
    expect(gate.allow(200), isTrue);
  });
}
