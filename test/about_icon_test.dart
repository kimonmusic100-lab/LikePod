import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/main.dart';
import 'package:likepod/providers/pod_state.dart';
import 'package:likepod/widgets/lcd_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('About shows the approved launcher icon at 32px', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sound_enabled': false,
      'haptics_enabled': false,
    });
    PackageInfo.setMockInitialValues(
      appName: 'LikePod',
      packageName: 'com.likepod.likepod',
      version: '0.1.0',
      buildNumber: '50',
      buildSignature: '',
    );
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LikePodApp());
    await tester.pump();
    final pod = tester.element(find.byType(LcdScreen)).read<PodState>();
    await tester.runAsync(() => pod.ready);

    pod.setSelectedIndex(3);
    pod.onSelect();
    await tester.pump();
    expect(pod.currentScreen.id, 'settings');

    final aboutIndex = pod.currentScreen.items.indexWhere(
      (item) => item.id == 'about',
    );
    expect(aboutIndex, greaterThanOrEqualTo(0));
    pod.setSelectedIndex(aboutIndex);
    pod.onSelect();
    await tester.pump();
    await tester.pump();
    expect(pod.currentScreen.id, 'about_view');

    final icon = find.byKey(const Key('about_app_icon'));
    expect(icon, findsOneWidget);
    expect(tester.getSize(icon), const Size(32, 32));
    expect(find.text('LikePod'), findsWidgets);
    expect(find.text('Version 0.1.0'), findsOneWidget);
    expect(find.text('作者：Kimonmusic'), findsOneWidget);
    await _saveShot(tester, 'about-vc50.png');

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
