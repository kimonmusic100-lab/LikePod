import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/providers/pod_state.dart';
import 'package:likepod/services/settings_store.dart';
import 'package:likepod/widgets/pod_chassis.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const system = BorderRadius.only(
    topLeft: Radius.circular(48),
    topRight: Radius.circular(47),
    bottomRight: Radius.circular(45),
    bottomLeft: Radius.circular(46),
  );

  test('missing or zero corners keep the previous shell', () {
    expect(
      chassisOuterRadius(isDesktopWide: false, systemCorners: null),
      isNull,
    );
    expect(
      chassisOuterRadius(isDesktopWide: false, systemCorners: BorderRadius.zero),
      isNull,
    );
    expect(
      chassisOuterRadius(isDesktopWide: true, systemCorners: null),
      BorderRadius.circular(36),
    );
    expect(
      chassisOuterRadius(isDesktopWide: true, systemCorners: BorderRadius.zero),
      BorderRadius.circular(36),
    );
  });

  test('each reported corner is kept on phone and wide layouts', () {
    expect(
      chassisOuterRadius(isDesktopWide: false, systemCorners: system),
      system,
    );
    expect(
      chassisOuterRadius(isDesktopWide: true, systemCorners: system),
      system,
    );
  });

  testWidgets('the phone shell follows the system corners without clipping', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'sound_enabled': false,
      'haptics_enabled': false,
    });
    final store = await SettingsStore.open();
    final pod = PodState(settingsStore: store);
    addTearDown(pod.dispose);

    await _pumpShell(tester, pod, width: 400, height: 800, corners: system);

    final shell = tester.widget<Container>(find.byKey(const Key('pod_chassis_shell')));
    final decoration = shell.decoration! as BoxDecoration;
    expect(decoration.borderRadius, system);
    expect(shell.clipBehavior, Clip.none);
    expect(decoration.border, isNull);
    pod.dispose();
  });

  testWidgets('a phone with no corners stays square', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sound_enabled': false,
      'haptics_enabled': false,
    });
    final store = await SettingsStore.open();
    final pod = PodState(settingsStore: store);
    addTearDown(pod.dispose);

    await _pumpShell(tester, pod, width: 400, height: 800, corners: null);

    final shell = tester.widget<Container>(find.byKey(const Key('pod_chassis_shell')));
    final decoration = shell.decoration! as BoxDecoration;
    expect(decoration.borderRadius, isNull);
    expect(shell.clipBehavior, Clip.none);
    pod.dispose();
  });

  testWidgets('a wide layout keeps radius 36 when the platform has none', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'sound_enabled': false,
      'haptics_enabled': false,
    });
    final store = await SettingsStore.open();
    final pod = PodState(settingsStore: store);
    addTearDown(pod.dispose);

    await _pumpShell(tester, pod, width: 800, height: 600, corners: null);

    final shell = tester.widget<Container>(find.byKey(const Key('pod_chassis_shell')));
    final decoration = shell.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(36));
    expect(shell.clipBehavior, Clip.none);
    pod.dispose();
  });
}

Future<void> _pumpShell(
  WidgetTester tester,
  PodState pod, {
  required double width,
  required double height,
  required BorderRadius? corners,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ChangeNotifierProvider<PodState>.value(
      value: pod,
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          displayCornerRadii: corners,
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: width,
            height: height,
            child: const PodChassis(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
