import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/main.dart';
import 'package:likepod/models/song_model.dart';
import 'package:likepod/providers/pod_state.dart';
import 'package:likepod/services/music_service.dart';
import 'package:likepod/services/playlist_library.dart';
import 'package:likepod/widgets/lcd_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _songs = [
  SongModel(
    id: 1,
    title: '晴天',
    artist: '周杰伦',
    album: '叶惠美',
    durationMs: 269000,
    uri: 'file:///a.mp3',
  ),
  SongModel(
    id: 2,
    title: '七里香',
    artist: '周杰伦',
    album: '七里香',
    durationMs: 299000,
    uri: 'file:///b.mp3',
  ),
  SongModel(
    id: 3,
    title: '夜曲',
    artist: '周杰伦',
    album: '十一月的萧邦',
    durationMs: 226000,
    uri: 'file:///c.mp3',
  ),
];

const _playlist = UserPlaylist(id: 'pl1', name: '通勤', songIds: [1, 3]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a playlist opens its songs; long-press center opens actions', (
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
    MusicService().debugSetLibrary(_songs);

    await tester.pumpWidget(const LikePodApp());
    await tester.pump();
    final pod = tester.element(find.byType(LcdScreen)).read<PodState>();
    await tester.runAsync(() => pod.ready);
    pod.seedPlaylistLibraryForTest(songs: _songs, playlists: const [_playlist]);
    await tester.pump();

    pod.onSelect();
    await tester.pump();
    pod.setSelectedIndex(1);
    pod.onSelect();
    await tester.pump();
    expect(pod.currentScreen.id, 'playlists');

    pod.setSelectedIndex(2);
    pod.onCenterLongPress();
    await tester.pump();
    expect(pod.currentScreen.id, 'playlist_actions:pl1');
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.text('添加歌曲'), findsOneWidget);
    expect(find.text('移除歌曲'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除播放列表'), findsOneWidget);
    expect(find.text('晴天'), findsNothing);

    pod.onMenu();
    await tester.pump();
    pod.onSelect();
    await tester.pump();
    expect(pod.currentScreen.id, 'playlist:pl1');
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('夜曲'), findsOneWidget);
    expect(find.text('七里香'), findsNothing);
    for (final action in ['播放全部', '添加歌曲', '移除歌曲', '重命名', '删除播放列表']) {
      expect(
        find.text(action),
        findsNothing,
        reason: 'short tap skips the action menu',
      );
    }
    await _saveShot(tester, 'playlist-songs-vc41.png');

    await tester.longPress(find.byKey(const Key('click_wheel_center')));
    await tester.pump();
    expect(pod.currentScreen.id, 'playlist_actions:pl1');
    expect(pod.currentScreen.title, '通勤');

    pod.setSelectedIndex(1);
    pod.onSelect();
    await tester.pump();
    expect(pod.currentScreen.id, 'playlist_add:pl1');
    expect(find.text('已添加'), findsNothing);
    pod.setSelectedIndex(1);
    await tester.pump();

    final added = tester.widget<Container>(
      find.byKey(const ValueKey('playlist_add_song:pl1_1')),
    );
    expect((added.decoration! as BoxDecoration).color, addedSongRowColor);
    final addedTexts = tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('playlist_add_song:pl1_1')),
        matching: find.byType(Text),
      ),
    );
    expect(addedTexts.first.style?.fontWeight, FontWeight.w700);
    expect(addedTexts.elementAt(1).style?.fontWeight, FontWeight.w700);

    final plain = tester.widget<Container>(
      find.byKey(const ValueKey('playlist_add_song:pl1_2')),
    );
    expect(
      (plain.decoration! as BoxDecoration).color,
      isNot(addedSongRowColor),
    );
    final plainTexts = tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('playlist_add_song:pl1_2')),
        matching: find.byType(Text),
      ),
    );
    expect(plainTexts.elementAt(1).style?.fontWeight, FontWeight.w500);
    await _saveShot(tester, 'playlist-add-vc41.png');

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
  try {
    final file = File('/opt/cursor/artifacts/$name');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  } catch (_) {}
}
