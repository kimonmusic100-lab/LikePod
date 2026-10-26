import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/providers/pod_state.dart';
import 'package:likepod/services/music_service.dart';
import 'package:likepod/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('music play mode cycles shuffle, single loop, then sequential', () async {
    final store = await SettingsStore.open();
    final pod = PodState(settingsStore: store);
    addTearDown(pod.dispose);

    expect(pod.playModeLabel, '顺序播放');
    expect(pod.shuffleMode, PodShuffleMode.off);
    expect(pod.repeatMode, PodRepeatMode.all);

    pod.cyclePlayMode();
    expect(pod.playModeLabel, '随机播放');
    expect(pod.shuffleMode, PodShuffleMode.songs);
    expect(pod.repeatMode, PodRepeatMode.all);

    pod.cyclePlayMode();
    expect(pod.playModeLabel, '单曲循环');
    expect(pod.shuffleMode, PodShuffleMode.off);
    expect(pod.repeatMode, PodRepeatMode.one);

    pod.cyclePlayMode();
    expect(pod.playModeLabel, '顺序播放');
    expect(pod.shuffleMode, PodShuffleMode.off);
    expect(pod.repeatMode, PodRepeatMode.all);

    pod.dispose();
  });
}
