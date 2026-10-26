import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/playlist_library.dart';

void main() {
  test('create, add, remove, rename, and delete', () {
    var lists = PlaylistLibrary.create(
      const [],
      id: 'pl1',
      name: '  通勤  ',
    );
    expect(lists.single.name, '通勤');
    expect(lists.single.songIds, isEmpty);

    lists = PlaylistLibrary.addSong(lists, id: 'pl1', songId: 4);
    lists = PlaylistLibrary.addSong(lists, id: 'pl1', songId: 4);
    lists = PlaylistLibrary.addSong(lists, id: 'pl1', songId: 9);
    expect(lists.single.songIds, [4, 9]);

    lists = PlaylistLibrary.removeSong(lists, id: 'pl1', songId: 4);
    expect(lists.single.songIds, [9]);

    lists = PlaylistLibrary.rename(lists, id: 'pl1', name: '夜里');
    expect(lists.single.name, '夜里');
    expect(PlaylistLibrary.rename(lists, id: 'pl1', name: '  '), lists);

    lists = PlaylistLibrary.create(lists, id: 'pl2', name: '另一个');
    lists = PlaylistLibrary.delete(lists, 'pl1');
    expect(lists.map((list) => list.id), ['pl2']);
    expect(PlaylistLibrary.create(lists, id: '', name: 'x'), lists);
  });

  test('json skips junk and round-trips', () {
    expect(PlaylistLibrary.parse('nope'), isEmpty);
    expect(PlaylistLibrary.parse('[{"id":"","name":"x"}]'), isEmpty);
    expect(PlaylistLibrary.parse('[{"name":"丢失 id"}]'), isEmpty);
    final raw = PlaylistLibrary.encode([
      const UserPlaylist(id: 'pl1', name: '通勤', songIds: [3, 8]),
    ]);
    final parsed = PlaylistLibrary.parse(raw);
    expect(parsed.single.name, '通勤');
    expect(parsed.single.songIds, [3, 8]);
  });
}