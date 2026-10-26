import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/pod_state.dart';
import 'services/playback_handler.dart';
import 'services/settings_store.dart';
import 'services/sound_service.dart';
import 'widgets/pod_chassis.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Foreground media service must be registered before playback starts.
  await PlaybackBootstrap.start();

  SettingsStore? settingsStore;
  try {
    settingsStore = await SettingsStore.open();
  } catch (e) {
    debugPrint('Settings unavailable: $e');
  }

  await SoundService().init();

  runApp(LikePodApp(settingsStore: settingsStore));
}

class LikePodApp extends StatelessWidget {
  final SettingsStore? settingsStore;

  const LikePodApp({super.key, this.settingsStore});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PodState(settingsStore: settingsStore),
      child: MaterialApp(
        title: 'LikePod',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Roboto',
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.light,
          ),
        ),
        home: const PodMainScreen(),
      ),
    );
  }
}

class PodMainScreen extends StatelessWidget {
  const PodMainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pod = context.watch<PodState>();
    final theme = pod.currentTheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final state = context.read<PodState>();
        if (state.handleSystemBack()) return;
        const MethodChannel('com.likepod/media').invokeMethod<void>('moveTaskToBack');
      },
      child: Scaffold(
        backgroundColor: theme.chassisPrimary,
        body: const PodChassis(),
      ),
    );
  }
}
