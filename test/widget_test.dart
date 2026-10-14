import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/main.dart';

void main() {
  testWidgets('LikePod smoke test renders correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const LikePodApp());
    expect(find.text('SepiaPod'), findsOneWidget);
    expect(find.text('MENU'), findsOneWidget);
  });
}
