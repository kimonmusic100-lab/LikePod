import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/main.dart';
import 'package:likepod/providers/pod_state.dart';
import 'package:likepod/widgets/lcd_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('wheel volume shows the live percent on Now Playing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LikePodApp());
    await tester.pump();

    final pod = tester.element(find.byType(LcdScreen)).read<PodState>();
    pod.openNowPlayingForTest();
    await tester.pump();
    expect(find.textContaining('%'), findsNothing, reason: 'hidden until the wheel moves');

    final start = pod.volume;
    pod.onRotate(-1);
    await tester.pump();
    final level = (start - 0.04).clamp(0.0, 1.0);
    expect(pod.volume, closeTo(level, 0.001));
    expect(find.text('${(level * 100).round()}%'), findsOneWidget);

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
    final png = data!.buffer.asUint8List();
    try {
      final file = File('/opt/cursor/artifacts/now-playing-vc40.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(png);
    } catch (_) {}

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
