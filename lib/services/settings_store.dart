import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Theme, click-wheel preferences, ratings, and resume point.
class AppSettings {
  static const defaultShell = 'spaceGray';
  static const defaultShuffle = 'off';
  static const defaultRepeat = 'all';

  final String shell;
  final bool soundEnabled;
  final bool hapticsEnabled;

  final String shuffle;
  final String repeat;

  /// First-level storage folders the library scans. Empty means all music.
  final List<String> musicFolders;

  /// Null when the user has never changed volume inside LikePod.
  final double? volume;
  final Map<int, int> ratings;
  final int? lastSongId;
  final int lastPositionMs;
  final List<int> lastQueueIds;

  const AppSettings({
    this.shell = defaultShell,
    this.soundEnabled = true,
    this.hapticsEnabled = true,
    this.shuffle = defaultShuffle,
    this.repeat = defaultRepeat,
    this.musicFolders = const [],
    this.volume,
    this.ratings = const {},
    this.lastSongId,
    this.lastPositionMs = 0,
    this.lastQueueIds = const [],
  });
}

class SettingsStore {
  SettingsStore(this._prefs);

  static const shellKey = 'shell_theme';
  static const soundKey = 'sound_enabled';
  static const hapticsKey = 'haptics_enabled';
  static const shuffleKey = 'shuffle_mode';
  static const repeatKey = 'repeat_mode';
  static const musicFoldersKey = 'music_folders';
  static const volumeKey = 'volume';
  static const ratingsKey = 'song_ratings';
  static const lastSongKey = 'last_song_id';
  static const lastPositionKey = 'last_position_ms';
  static const lastQueueKey = 'last_queue_ids';

  final SharedPreferences _prefs;

  static Future<SettingsStore> open() async {
    return SettingsStore(await SharedPreferences.getInstance());
  }

  AppSettings load() {
    return AppSettings(
      shell: _prefs.getString(shellKey) ?? AppSettings.defaultShell,
      soundEnabled: _prefs.getBool(soundKey) ?? true,
      hapticsEnabled: _prefs.getBool(hapticsKey) ?? true,
      shuffle: _prefs.getString(shuffleKey) ?? AppSettings.defaultShuffle,
      repeat: _prefs.getString(repeatKey) ?? AppSettings.defaultRepeat,
      musicFolders: _decodeFolders(_prefs.getString(musicFoldersKey)),
      volume: _prefs.containsKey(volumeKey)
          ? _prefs.getDouble(volumeKey)
          : null,
      ratings: _decodeRatings(_prefs.getString(ratingsKey)),
      lastSongId: _prefs.containsKey(lastSongKey)
          ? _prefs.getInt(lastSongKey)
          : null,
      lastPositionMs: _prefs.getInt(lastPositionKey) ?? 0,
      lastQueueIds: _decodeQueue(_prefs.getString(lastQueueKey)),
    );
  }

  Future<void> save(AppSettings settings) async {
    final ratings = <String, int>{
      for (final entry in settings.ratings.entries)
        if (entry.value > 0) entry.key.toString(): entry.value.clamp(0, 5),
    };
    final writes = <Future<bool>>[
      _prefs.setString(shellKey, settings.shell),
      _prefs.setBool(soundKey, settings.soundEnabled),
      _prefs.setBool(hapticsKey, settings.hapticsEnabled),
      _prefs.remove('high_quality_mode'),
      _prefs.setString(shuffleKey, settings.shuffle),
      _prefs.setString(repeatKey, settings.repeat),
      _prefs.setString(musicFoldersKey, jsonEncode(settings.musicFolders)),
      _prefs.setString(ratingsKey, jsonEncode(ratings)),
      _prefs.setInt(
        lastPositionKey,
        settings.lastPositionMs < 0 ? 0 : settings.lastPositionMs,
      ),
      _prefs.setString(lastQueueKey, jsonEncode(settings.lastQueueIds)),
    ];
    if (settings.volume != null) {
      writes.add(_prefs.setDouble(volumeKey, settings.volume!.clamp(0.0, 1.0)));
    } else {
      writes.add(_prefs.remove(volumeKey));
    }
    if (settings.lastSongId != null) {
      writes.add(_prefs.setInt(lastSongKey, settings.lastSongId!));
    } else {
      writes.add(_prefs.remove(lastSongKey));
    }
    await Future.wait(writes);
  }

  static Map<int, int> _decodeRatings(String? raw) {
    final ratings = <int, int>{};
    if (raw == null || raw.isEmpty) return ratings;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return ratings;
      decoded.forEach((key, value) {
        final id = int.tryParse(key.toString());
        final stars = value is num ? value.toInt() : int.tryParse('$value');
        if (id != null && stars != null) {
          ratings[id] = stars.clamp(0, 5);
        }
      });
    } catch (_) {}
    return ratings;
  }

  static List<int> _decodeQueue(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final queue = <int>[];
      for (final item in decoded) {
        if (item is num) {
          queue.add(item.toInt());
        } else {
          final parsed = int.tryParse('$item');
          if (parsed != null) queue.add(parsed);
        }
      }
      return queue;
    } catch (_) {
      return const [];
    }
  }

  static List<String> _decodeFolders(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is String && item.isNotEmpty) item,
      ];
    } catch (_) {
      return const [];
    }
  }
}
