import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Chinese menu, artwork split, and click wheel stay intact', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LikePodApp());
    await tester.pump();

    expect(find.text('LikePod'), findsOneWidget);
    expect(find.text('iPod'), findsNothing);
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('照片'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('Podcast'), findsNothing);
    expect(find.text('附加功能'), findsNothing);
    expect(find.text('随机播放歌曲'), findsNothing);
    expect(find.text('MENU'), findsOneWidget);

    // Music is the default selection, so one tap opens the Chinese music menu.
    await tester.tap(find.text('音乐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Cover Flow'), findsOneWidget);
    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('表演者'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('歌曲'), findsOneWidget);
    expect(find.text('顺序播放'), findsOneWidget);
    expect(find.text('随机播放'), findsNothing);
    expect(find.text('单曲循环'), findsNothing);
    expect(find.text('Genius 混合曲目'), findsNothing);
    expect(find.text('选集'), findsNothing);
    expect(find.text('风格'), findsNothing);
    expect(find.text('作曲家'), findsNothing);
    expect(find.text('正在播放'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
