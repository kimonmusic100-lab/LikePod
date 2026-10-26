import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/providers/pod_state.dart';
import 'package:likepod/services/settings_store.dart';
import 'package:likepod/theme/pod_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults when nothing has been saved', () async {
    final store = await SettingsStore.open();
    final settings = store.load();

    expect(settings.shell, AppSettings.defaultShell);
    expect(settings.soundEnabled, isTrue);
    expect(settings.hapticsEnabled, isTrue);
    expect(settings.shuffle, 'off');
    expect(settings.repeat, 'all');
    expect(settings.volume, isNull);
    expect(settings.ratings, isEmpty);
    expect(settings.lastSongId, isNull);
    expect(settings.lastPositionMs, 0);
    expect(settings.lastQueueIds, isEmpty);
  });

  test('theme, ratings, and resume point round-trip', () async {
    final store = await SettingsStore.open();
    await store.save(
      const AppSettings(
        shell: 'u2Special',
        soundEnabled: false,
        hapticsEnabled: true,
        shuffle: 'songs',
        repeat: 'one',
        volume: 0.42,
        ratings: {12: 5, 4: 0, -1: 3},
        lastSongId: 12,
        musicFolders: ['/storage/emulated/0/Music', '/storage/0000-0000/Netease'],
        lastPositionMs: 18600,
        lastQueueIds: [12, 4, -1],
      ),
    );

    final loaded = store.load();
    expect(loaded.shell, 'u2Special');
    expect(loaded.soundEnabled, isFalse);
    expect(loaded.hapticsEnabled, isTrue);
    expect(loaded.shuffle, 'songs');
    expect(loaded.repeat, 'one');
    expect(loaded.volume, closeTo(0.42, 0.001));
    expect(loaded.ratings[12], 5);
    expect(loaded.ratings[4], isNull);
    expect(loaded.ratings[-1], 3);
    expect(loaded.lastSongId, 12);
    expect(loaded.lastPositionMs, 18600);
    expect(loaded.lastQueueIds, [12, 4, -1]);
    expect(loaded.musicFolders, [
      '/storage/emulated/0/Music',
      '/storage/0000-0000/Netease',
    ]);
  });

  test('music folders decode tolerates junk and empty means all', () async {
    SharedPreferences.setMockInitialValues({
      SettingsStore.musicFoldersKey: '["/storage/emulated/0/Music", "", 42, null]',
    });
    final store = await SettingsStore.open();
    expect(store.load().musicFolders, ['/storage/emulated/0/Music']);

    SharedPreferences.setMockInitialValues({
      SettingsStore.musicFoldersKey: 'not json',
    });
    expect((await SettingsStore.open()).load().musicFolders, isEmpty);
  });

  test('invalid rating stars are clamped', () async {
    SharedPreferences.setMockInitialValues({
      SettingsStore.ratingsKey: '{"9": 8, "3": -2}',
    });
    final store = await SettingsStore.open();
    final loaded = store.load();
    expect(loaded.ratings[9], 5);
    expect(loaded.ratings[3], 0);
  });

  testWidgets('shell theme is persisted by PodState', (tester) async {
    final store = await SettingsStore.open();
    final pod = PodState(settingsStore: store);
    addTearDown(pod.dispose);

    await pod.ready;
    pod.setShellType(ShellThemeType.stealthBlack);
    await pod.flushSettings();

    final loaded = store.load();
    expect(loaded.shell, 'stealthBlack');
    expect(pod.shellType, ShellThemeType.stealthBlack);
    pod.dispose();
  });
}
