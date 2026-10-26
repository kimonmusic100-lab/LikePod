import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/main.dart';
import 'package:likepod/providers/pod_state.dart';
import 'package:likepod/services/spectrum_feed.dart';
import 'package:likepod/services/wave_style.dart';
import 'package:likepod/widgets/lcd_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Now Playing draws each waveform and remembers the choice', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'sound_enabled': false,
      'haptics_enabled': false,
    });
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LikePodApp());
    await tester.pump();
    final pod = tester.element(find.byType(LcdScreen)).read<PodState>();
    await tester.runAsync(() => pod.ready);
    pod.openNowPlayingForTest();
    await tester.pump();

    SpectrumFeed.instance.debugSetLevels(const [
      0.15,
      0.35,
      0.62,
      0.9,
      0.7,
      0.4,
      0.25,
      0.55,
      0.85,
      1.0,
      0.72,
      0.38,
      0.22,
      0.48,
      0.66,
      0.5,
      0.3,
      0.18,
      0.42,
      0.58,
      0.36,
      0.2,
      0.44,
      0.6,
    ]);
    expect(pod.waveStyle, WaveStyle.mirror);
    expect(
      find.byKey(const ValueKey('now_playing_wave_mirror')),
      findsOneWidget,
    );
    for (final style in WaveStyle.values) {
      pod.setWaveStyle(style);
      await tester.pump();
      expect(pod.waveStyle, style);
      expect(
        find.byKey(ValueKey('now_playing_wave_${style.name}')),
        findsOneWidget,
      );
      await _saveShot(tester, 'now-playing-wave-${style.name}-vc44.png');
    }

    await tester.longPress(find.byKey(const Key('click_wheel_center')));
    await tester.pump();
    expect(pod.currentScreen.id, 'wave_style');
    expect(pod.currentScreen.title, '波形特效');
    expect(find.text('镜像柱'), findsOneWidget);
    expect(find.text('点阵柱'), findsOneWidget);
    expect(find.text('柔光柱'), findsOneWidget);
    expect(find.text('经典柱状'), findsNothing);
    expect(find.text('示波曲线'), findsNothing);
    expect(find.text('当前'), findsWidgets);
    await _saveShot(tester, 'now-playing-wave-menu-vc44.png');

    pod.setSelectedIndex(WaveStyle.dots.index);
    pod.onSelect();
    await tester.pump();
    expect(pod.waveStyle, WaveStyle.dots);

    pod.onMenu();
    await tester.pump();
    expect(pod.currentScreen.id, 'now_playing_view');
    expect(find.byKey(const ValueKey('now_playing_wave_dots')), findsOneWidget);

    pod.onMenu();
    await tester.pump();
    expect(pod.currentScreen.id, 'main');
    pod.setSelectedIndex(3);
    pod.onSelect();
    await tester.pump();
    expect(pod.currentScreen.id, 'settings');
    expect(find.text('波形特效'), findsOneWidget);
    expect(find.text('点阵柱'), findsOneWidget);
    expect(find.text('经典柱状'), findsNothing);

    pod.setSelectedIndex(3);
    pod.onSelect();
    await tester.pump();
    expect(pod.currentScreen.id, 'wave_style');
    pod.setSelectedIndex(WaveStyle.glow.index);
    pod.onSelect();
    await tester.pump();
    expect(pod.waveStyle, WaveStyle.glow);

    await tester.runAsync(() => pod.flushSettings());
    final prefs = await tester.runAsync(() => SharedPreferences.getInstance());
    expect(prefs!.getString('wave_style'), 'glow');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}

Future<void> _saveShot(WidgetTester tester, String name) async {
  RenderRepaintBoundary? shot;
  var area = 0.0;
  for (final element in find.byType(RepaintBoundary).evaluate()) {
    final render = element.renderObject;
    if (render is! RenderRepaintBoundary || !render.hasSize) continue;
    final next = render.size.width * render.size.height;
    if (next > area) {
      area = next;
      shot = render;
    }
  }
  final boundary = shot;
  expect(boundary, isNotNull);
  final image = await tester.runAsync(() => boundary!.toImage(pixelRatio: 2));
  final data = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  final file = File('/opt/cursor/artifacts/$name');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(data!.buffer.asUint8List());
}
