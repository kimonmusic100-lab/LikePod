import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/pod_state.dart';
import 'services/sound_service.dart';
import 'widgets/pod_chassis.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hide system status bar & navigation bar by default for full-screen immersive retro experience
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize click sound audio player
  await SoundService().init();

  runApp(const LikePodApp());
}

class LikePodApp extends StatelessWidget {
  const LikePodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PodState(),
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

    return Scaffold(
      backgroundColor: theme.chassisPrimary,
      body: const PodChassis(),
    );
  }
}
