import 'dart:convert';

/// A user-made playlist. Song ids point at the MediaStore library.
class UserPlaylist {
  final String id;
  final String name;
  final List<int> songIds;

  const UserPlaylist({
    required this.id,
    required this.name,
    this.songIds = const [],
  });

  UserPlaylist copyWith({String? name, List<int>? songIds}) {
    return UserPlaylist(
      id: id,
      name: name ?? this.name,
      songIds: songIds ?? this.songIds,
    );
  }
}

/// Local playlist edits. Persistence is a JSON list in [SettingsStore].
class PlaylistLibrary {
  static List<UserPlaylist> parse(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final lists = <UserPlaylist>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final id = item['id'];
        final name = item['name'];
        if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
          continue;
        }
        final songs = <int>[];
        final rawIds = item['songIds'];
        if (rawIds is List) {
          for (final songId in rawIds) {
            if (songId is num) {
              songs.add(songId.toInt());
            } else {
              final parsed = int.tryParse('$songId');
              if (parsed != null) songs.add(parsed);
            }
          }
        }
        lists.add(UserPlaylist(id: id, name: name, songIds: songs));
      }
      return lists;
    } catch (_) {
      return const [];
    }
  }

  static String encode(List<UserPlaylist> lists) {
    return jsonEncode([
      for (final list in lists)
        {'id': list.id, 'name': list.name, 'songIds': list.songIds},
    ]);
  }

  static UserPlaylist? find(List<UserPlaylist> lists, String id) {
    for (final list in lists) {
      if (list.id == id) return list;
    }
    return null;
  }

  static List<UserPlaylist> create(
    List<UserPlaylist> lists, {
    required String id,
    required String name,
  }) {
    final trimmed = name.trim();
    if (id.isEmpty || trimmed.isEmpty) return lists;
    return [...lists, UserPlaylist(id: id, name: trimmed)];
  }

  static List<UserPlaylist> rename(
    List<UserPlaylist> lists, {
    required String id,
    required String name,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return lists;
    return [
      for (final list in lists)
        if (list.id == id) list.copyWith(name: trimmed) else list,
    ];
  }

  static List<UserPlaylist> delete(List<UserPlaylist> lists, String id) {
    return [for (final list in lists) if (list.id != id) list];
  }

  static List<UserPlaylist> addSong(
    List<UserPlaylist> lists, {
    required String id,
    required int songId,
  }) {
    return [
      for (final list in lists)
        if (list.id != id)
          list
        else if (list.songIds.contains(songId))
          list
        else
          list.copyWith(songIds: [...list.songIds, songId]),
    ];
  }

  static List<UserPlaylist> removeSong(
    List<UserPlaylist> lists, {
    required String id,
    required int songId,
  }) {
    return [
      for (final list in lists)
        if (list.id != id)
          list
        else
          list.copyWith(
            songIds: [for (final song in list.songIds) if (song != songId) song],
          ),
    ];
  }
}
