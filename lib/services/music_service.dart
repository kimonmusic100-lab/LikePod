import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/song_model.dart';
import 'audio_engine.dart';
import 'focus_route.dart';
import 'output_probe.dart';

enum PodShuffleMode { off, songs }

enum PodRepeatMode { off, all, one }

class MusicService {
  static final MusicService _instance = MusicService._internal();
  factory MusicService() => _instance;
  MusicService._internal() {
    _engine.onFocusLost = _onNativeFocusLost;
    _engine.onFocusGained = _onNativeFocusGained;
  }

  static const MethodChannel _channel = MethodChannel('com.likepod/media');
  final AudioEngine _engine = AudioEngine();
  bool _askedNotificationPermission = false;
  bool _anchorHooked = false;
  bool _intendPlay = false;
  final FocusYield _focusYield = FocusYield();

  /// Bumps on every yield pause, yield resume, and user transport change.
  /// A late pause from the old generation must not stop the newer play.
  int _transportEpoch = 0;

  /// Bumps when a fade should stop (user volume, user pause, a new play).
  int _fadeEpoch = 0;

  /// Another app took the output. Pause the player but keep the focus
  /// request, so Android can hand it back when that app lets go.
  void _onNativeFocusLost() {
    final playing = _engine.player?.playing ?? false;
    _focusYield.noteFocusLost(active: playing || _intendPlay);
    if (!_focusYield.pausedByFocusLoss) return;
    final epoch = ++_transportEpoch;
    unawaited(_pauseYieldedPlayer(epoch));
  }

  Future<void> _pauseYieldedPlayer(int epoch) async {
    final player = _engine.player;
    if (player == null || !player.playing || epoch != _transportEpoch) return;
    try {
      await player.pause();
    } catch (e) {
      debugPrint('yield pause failed: $e');
    }
    if (epoch != _transportEpoch && _intendPlay) {
      try {
        await player.play();
      } catch (e) {
        debugPrint('yield pause undo failed: $e');
      }
    }
  }

  bool _resumeInFlight = false;

  /// Focus returned from the interrupting app, not from our own request.
  void _onNativeFocusGained() {
    if (_resumeInFlight) return;
    if (_engine.playerPlaying()) {
      _focusYield.noteUserPause();
      return;
    }
    if (!_focusYield.pausedByFocusLoss) return;
    if (currentSong == null) {
      _focusYield.noteUserPause();
      return;
    }
    final epoch = ++_transportEpoch;
    unawaited(_resumeAfterYield(epoch));
  }

  Future<void> _resumeAfterYield(int epoch) async {
    if (_resumeInFlight || epoch != _transportEpoch) return;
    _resumeInFlight = true;
    try {
      await Future<void>.delayed(yieldResumeGap);
      if (epoch != _transportEpoch || !_focusYield.pausedByFocusLoss) return;
      if (_engine.playerPlaying()) return;
      await resume(fadeIn: true);
    } finally {
      _resumeInFlight = false;
    }
  }

  final Map<int, Uint8List?> _artworkCache = {};

  /// Windows/desktop: albumId -> sidecar cover file path.
  final Map<int, String> _albumArtPaths = {};
  List<SongModel> _allSongs = [];
  bool _libraryPinned = false;
  List<SongModel> _currentQueue = [];
  int _currentQueueIndex = -1;

  PodShuffleMode _shuffleMode = PodShuffleMode.off;
  PodRepeatMode _repeatMode = PodRepeatMode.all;

  /// Folders the user added manually. The library is a strict whitelist:
  /// nothing is scanned while this is empty.
  List<String> _musicFolders = const [];

  /// Every song file path from the last raw MediaStore scan, unfiltered.
  final List<String> _rawPaths = [];

  /// Every directory that leads to at least one song, plus volume roots.
  final Set<String> _allDirs = {};

  double _volume = 0.7;
  bool _isInitialized = false;

  bool get hasPlayer => _engine.hasPlayer;

  OutputSnapshot get outputSnapshot => _engine.snapshot;

  set onOutputChanged(void Function()? listener) {
    _engine.onSnapshot = listener;
  }

  /// Creates the shared [AudioPlayer] once. Returns false when the platform
  /// player cannot be constructed (widget tests without a plugin, for example).
  bool ensurePlayer() {
    final ok = _engine.ensurePlayer();
    final player = _engine.player;
    if (ok && player != null && !_anchorHooked) {
      _anchorHooked = true;
      player.playingStream.listen((playing) {
        unawaited(anchorPlayback(playing));
      });
    }
    return ok;
  }

  /// Holds audio focus and the playback foreground service while [playing],
  /// including after the activity has left the screen.
  Future<void> anchorPlayback(bool playing) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final finished =
          _engine.player?.processingState == ProcessingState.completed;
      await _channel.invokeMethod<bool>(
        playing ? 'holdPlayback' : 'releasePlayback',
        playing ? null : {'userStopped': !_intendPlay || finished},
      );
    } catch (e) {
      debugPrint('Playback anchor failed: $e');
    }
  }

  AudioPlayer get player {
    if (!ensurePlayer()) {
      throw StateError('AudioPlayer unavailable');
    }
    return _engine.player!;
  }

  List<SongModel> get allSongs => _allSongs;

  void setMusicFolders(List<String> folders) {
    _musicFolders = List.unmodifiable(folders);
  }

  /// Volume roots that hold at least one song, e.g. `/storage/emulated/0`.
  List<String> storageRoots() {
    final roots = <String>{};
    for (final dir in _allDirs) {
      final root = volumeRootOf(dir);
      if (root != null) roots.add(root);
    }
    return roots.toList()..sort();
  }

  /// Direct child directories of [dir] that lead to at least one song.
  List<String> childFolders(String dir) {
    final children = <String>[];
    for (final candidate in _allDirs) {
      final parent = parentDirOf(candidate);
      if (parent == dir) children.add(candidate);
    }
    return children..sort();
  }

  /// Song count anywhere inside [folder] (recursive).
  int songsUnder(String folder) {
    var count = 0;
    for (final path in _rawPaths) {
      if (pathUnder(path, folder)) count++;
    }
    return count;
  }

  /// Whether [path] lies inside [folder] (or equals it), on a path boundary.
  static bool pathUnder(String path, String folder) {
    if (folder.isEmpty) return false;
    if (path == folder) return true;
    return path.length > folder.length &&
        path.startsWith(folder) &&
        (folder.endsWith('/') || path[folder.length] == '/');
  }

  /// Parent directory of a path, or null at the root. Works for files and
  /// directories alike.
  static String? parentDirOf(String path) {
    final index = path.lastIndexOf('/');
    if (index <= 0) return null;
    return path.substring(0, index);
  }

  /// Final path segment.
  static String baseName(String path) {
    final index = path.lastIndexOf('/');
    return index < 0 ? path : path.substring(index + 1);
  }

  /// `/storage/emulated/0/...` -> `/storage/emulated/0`;
  /// `/storage/XXXX-XXXX/...` -> `/storage/XXXX-XXXX`. Null otherwise.
  static String? volumeRootOf(String path) {
    if (!path.startsWith('/storage/')) return null;
    final parts = path.split('/')..removeWhere((segment) => segment.isEmpty);
    final volumeIndex = parts.length > 1 && parts[1] == 'emulated' ? 3 : 2;
    if (parts.length < volumeIndex) return null;
    return '/${parts.sublist(0, volumeIndex).join('/')}';
  }

  /// Short label for an added folder: the path after its volume root, with
  /// an SD marker, e.g. `Music/周杰伦` or `SD · Netease`.
  static String folderLabel(String folder) {
    final root = volumeRootOf(folder);
    if (root == null) return folder;
    final sd = !root.startsWith('/storage/emulated/');
    if (folder == root) {
      return sd ? 'SD 卡' : '内部存储';
    }
    final relative = folder.substring(root.length + 1);
    return sd ? 'SD · $relative' : relative;
  }

  double get volume => _volume;
  PodShuffleMode get shuffleMode => _shuffleMode;
  PodRepeatMode get repeatMode => _repeatMode;
  int get queueLength => _currentQueue.length;
  int get queueIndex => _currentQueueIndex;
  SongModel? get currentSong =>
      (_currentQueueIndex >= 0 && _currentQueueIndex < _currentQueue.length)
      ? _currentQueue[_currentQueueIndex]
      : null;

  List<int> get currentQueueIds =>
      _currentQueue.map((song) => song.id).toList(growable: false);

  Duration get position => _engine.player?.position ?? Duration.zero;

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    if (!ensurePlayer()) {
      _engine.startListening();
      await _engine.refreshRoute();
      await scanLocalMusic();
      return;
    }
    final player = _engine.player!;

    await initVolume();
    _engine.startListening();
    await _engine.refreshRoute();

    player.playbackEventStream.listen(
      (event) {},
      onError: (Object e, StackTrace st) {
        debugPrint('JustAudio playbackEvent error: $e');
      },
    );

    // Auto next track only on true completion
    player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        final pos = player.position.inSeconds;
        final dur = player.duration?.inSeconds ?? 0;
        if (dur > 5 && pos >= dur - 2) {
          playNext();
        }
      }
    });

    await scanLocalMusic();
  }

  Future<bool> requestPermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    if (await Permission.audio.isGranted) return true;
    final audioStatus = await Permission.audio.request();
    if (audioStatus.isGranted) return true;

    if (await Permission.storage.isGranted) return true;
    final storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<List<SongModel>> scanLocalMusic() async {
    final List<SongModel> songs = [];
    _rawPaths.clear();
    _allDirs.clear();

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final hasPermission = await requestPermission();
        if (hasPermission) {
          final List<dynamic>? result = await _channel.invokeMethod('getSongs');
          if (result != null) {
            for (final item in result) {
              final map = Map<String, dynamic>.from(item as Map);
              final contentUri = map['contentUri'] as String?;
              final path = map['path'] as String? ?? '';

              // Build the browsable directory tree from the raw scan so the
              // picker can navigate every folder that leads to a song.
              if (path.startsWith('/storage/')) {
                _rawPaths.add(path);
                var dir = parentDirOf(path);
                while (dir != null) {
                  _allDirs.add(dir);
                  dir = parentDirOf(dir);
                }
              }
              // Whitelist: a song is kept only inside an added folder.
              if (_musicFolders.isNotEmpty &&
                  !_musicFolders.any((f) => pathUnder(path, f))) {
                continue;
              }

              // Prioritize direct filesystem path to prevent Android ContentResolver stream timeouts
              String playbackUri = '';
              if (path.isNotEmpty && File(path).existsSync()) {
                playbackUri = path;
              } else if (contentUri != null && contentUri.isNotEmpty) {
                playbackUri = contentUri;
              } else {
                playbackUri = path;
              }

              songs.add(
                SongModel(
                  id: (map['id'] as num).toInt(),
                  title: map['title'] as String? ?? 'Unknown Title',
                  artist: map['artist'] as String? ?? 'Unknown Artist',
                  album: map['album'] as String? ?? 'Unknown Album',
                  durationMs: (map['duration'] as num?)?.toInt() ?? 0,
                  uri: playbackUri,
                  albumId: (map['albumId'] as num?)?.toInt(),
                ),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('Error querying MediaStore via MethodChannel: $e');
      }
    } else if (!kIsWeb && Platform.isWindows) {
      // Windows Desktop fallback — group by folder as album, pick sidecar covers.
      try {
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null) {
          final musicDir = Directory('$userProfile\\Music');
          if (musicDir.existsSync()) {
            final files = musicDir.listSync(recursive: true);
            int idCounter = 1;
            final Map<String, int> albumIdByDir = {};
            int nextAlbumId = 1;
            for (final file in files) {
              if (file is File) {
                final ext = file.path.split('.').last.toLowerCase();
                if (['mp3', 'wav', 'flac', 'm4a', 'aac', 'ogg'].contains(ext)) {
                  final filename = file.uri.pathSegments.last.replaceAll(
                    '.$ext',
                    '',
                  );
                  final parent = file.parent;
                  final albumDir = parent.path;
                  final albumName = parent.uri.pathSegments.isNotEmpty
                      ? parent.uri.pathSegments.last
                      : 'Music Library';
                  final albumId = albumIdByDir.putIfAbsent(albumDir, () {
                    final id = nextAlbumId++;
                    final cover = _findSidecarCover(parent);
                    if (cover != null) {
                      _albumArtPaths[id] = cover.path;
                    }
                    return id;
                  });
                  songs.add(
                    SongModel(
                      id: idCounter++,
                      title: filename,
                      artist: 'Local Artist',
                      album: albumName,
                      durationMs: 180000,
                      uri: file.path,
                      albumId: albumId,
                    ),
                  );
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error scanning Windows Music folder: $e');
      }
    }

    // Sample tracks only when the device scan found nothing at all; an
    // empty whitelist is a user choice, not an empty device.
    if (songs.isEmpty && _rawPaths.isEmpty) {
      songs.addAll(_getSamplePlayableTracks());
    }

    if (_libraryPinned) return _allSongs;
    _allSongs = songs;
    return songs;
  }

  /// Widget tests pin a library so a later device scan cannot replace it.
  @visibleForTesting
  void debugSetLibrary(List<SongModel> songs) {
    _libraryPinned = true;
    _allSongs = List<SongModel>.from(songs);
  }

  /// Shown when the device library is empty. This file is sample music,
  /// not the click-wheel sounds (`tick.wav` and `select.wav`).
  List<SongModel> _getSamplePlayableTracks() {
    return const [
      SongModel(
        id: -1,
        title: 'Retro Starlight Groove',
        artist: 'LikePod Ensemble',
        album: 'Analog Memories Vol. 1',
        durationMs: 218000,
        uri: 'asset:///assets/audio/click.wav',
      ),
      SongModel(
        id: -2,
        title: 'Velvet Highway',
        artist: 'Vintage Soundworks',
        album: 'Analog Memories Vol. 1',
        durationMs: 194000,
        uri: 'asset:///assets/audio/click.wav',
      ),
      SongModel(
        id: -3,
        title: 'Sunset Neon Boulevard',
        artist: 'Horizon Wave',
        album: 'Golden Era Classics',
        durationMs: 254000,
        uri: 'asset:///assets/audio/click.wav',
      ),
      SongModel(
        id: -4,
        title: 'Midnight Echoes',
        artist: 'Acoustic Project',
        album: 'Golden Era Classics',
        durationMs: 182000,
        uri: 'asset:///assets/audio/click.wav',
      ),
    ];
  }

  Future<void> playSong(SongModel song, {List<SongModel>? queue}) {
    return _openSong(song, queue: queue, position: Duration.zero, play: true);
  }

  /// Loads [song] at [position] and leaves playback paused (resume on next launch).
  Future<bool> restorePaused(
    SongModel song, {
    required List<SongModel> queue,
    required Duration position,
  }) {
    return _openSong(song, queue: queue, position: position, play: false);
  }

  Future<bool> _openSong(
    SongModel song, {
    List<SongModel>? queue,
    required Duration position,
    required bool play,
  }) async {
    if (!ensurePlayer()) return false;
    final player = _engine.player!;

    if (queue != null && queue.isNotEmpty) {
      _currentQueue = List<SongModel>.from(queue);
    } else if (!_currentQueue.contains(song)) {
      _currentQueue = [song];
    }

    _currentQueueIndex = _currentQueue.indexOf(song);
    if (_currentQueueIndex < 0) {
      _currentQueue = [song];
      _currentQueueIndex = 0;
    }

    try {
      _transportEpoch++;
      _focusYield.noteUserPause();
      _intendPlay = play;
      var focusGranted = true;
      if (play && !kIsWeb && Platform.isAndroid) {
        try {
          focusGranted =
              await _channel.invokeMethod<bool>('holdPlayback', {
                'user': true,
              }) ==
              true;
        } catch (_) {
          focusGranted = false;
        }
        if (!focusGranted) {
          // Focus is held by a call or another app. Do not start playback.
          _intendPlay = false;
        }
      }

      if (song.uri.startsWith('asset:///')) {
        final assetPath = song.uri.replaceFirst('asset:///', '');
        await player.setAsset(assetPath);
      } else if (File(song.uri).existsSync()) {
        await player.setFilePath(song.uri);
      } else if (song.uri.startsWith('content://') ||
          song.uri.startsWith('file://')) {
        await player.setAudioSource(
          AudioSource.uri(Uri.parse(song.uri)),
          preload: true,
        );
      } else {
        await player.setFilePath(song.uri);
      }
      if (position > Duration.zero) {
        await player.seek(position);
      }
      if (play && focusGranted) {
        await _ensureNotificationPermission();
        unawaited(
          player.play().then(
            (_) {},
            onError: (Object e) {
              debugPrint('play failed on open: $e');
            },
          ),
        );
      }
      await _engine.syncRoute();
      return true;
    } catch (e) {
      debugPrint('Error playing song ${song.title}: $e');
      return false;
    }
  }

  Future<void> _ensureNotificationPermission() async {
    if (_askedNotificationPermission || kIsWeb || !Platform.isAndroid) return;
    _askedNotificationPermission = true;
    try {
      await Permission.notification.request();
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
    // HyperOS freezes the process ~20s after audio pauses. The whitelist
    // keeps notification controls usable after that pause.
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  Future<void> pause() async {
    _transportEpoch++;
    _fadeEpoch++;
    _focusYield.noteUserPause();
    _intendPlay = false;
    try {
      await _engine.player?.setVolume(1.0);
    } catch (_) {}
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('userPause');
      } catch (_) {}
    }
    final player = _engine.player;
    if (player == null || !player.playing) return;
    await player.pause();
  }

  Future<void> resume({bool fadeIn = false}) async {
    if (!ensurePlayer()) return;
    _transportEpoch++;
    if (!fadeIn) _fadeEpoch++;
    final yielded = _focusYield.pausedByFocusLoss;
    _focusYield.noteUserPause();
    await _ensureNotificationPermission();
    if (currentSong == null && _allSongs.isNotEmpty) {
      await playSong(_allSongs.first, queue: _allSongs);
      return;
    }
    _intendPlay = true;
    if (!kIsWeb && Platform.isAndroid) {
      var granted = false;
      try {
        granted =
            await _channel.invokeMethod<bool>('holdPlayback', {'user': true}) ==
            true;
      } catch (_) {}
      if (!granted) {
        _intendPlay = false;
        if (yielded) _focusYield.noteFocusLost(active: true);
        try {
          await _engine.player?.setVolume(1.0);
        } catch (_) {}
        return;
      }
    }
    final player = _engine.player!;
    try {
      // Yield resume ramps the player only. System volume stays put, and
      // unity at the end is the user's current level.
      await player.setVolume(fadeIn ? 0 : 1);
    } catch (_) {}
    unawaited(
      player.play().then(
        (_) {},
        onError: (Object e) {
          debugPrint('play failed after resume: $e');
        },
      ),
    );
    if (fadeIn) unawaited(_fadeToUnity());
    await _engine.syncRoute();
  }

  Future<void> _fadeToUnity() async {
    final fade = ++_fadeEpoch;
    final player = _engine.player;
    if (player == null) return;
    final started = DateTime.now();
    for (var step = 1; step <= yieldFadeSteps; step++) {
      final at = yieldFadeStepAt(step, yieldFadeSteps, yieldFadeDuration);
      final wait = started.add(at).difference(DateTime.now());
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      if (fade != _fadeEpoch || !_intendPlay) {
        try {
          await player.setVolume(1);
        } catch (_) {}
        return;
      }
      try {
        await player.setVolume(yieldFadeGain(step, yieldFadeSteps));
      } catch (_) {}
    }
  }

  Future<void> togglePlayPause() async {
    if (_engine.player?.playing == true) {
      await pause();
    } else {
      await resume();
    }
  }

  void setShuffleMode(PodShuffleMode mode) {
    _shuffleMode = mode;
  }

  void setRepeatMode(PodRepeatMode mode) {
    _repeatMode = mode;
  }

  Future<void> playNext() async {
    if (_currentQueue.isEmpty) return;

    if (_repeatMode == PodRepeatMode.one) {
      _focusYield.noteUserPause();
      await seek(Duration.zero);
      _intendPlay = true;
      await _engine.player?.play();
      return;
    }

    int nextIndex = _currentQueueIndex + 1;
    if (_shuffleMode == PodShuffleMode.songs && _currentQueue.length > 1) {
      final rand = Random();
      nextIndex = rand.nextInt(_currentQueue.length);
      if (nextIndex == _currentQueueIndex) {
        nextIndex = (nextIndex + 1) % _currentQueue.length;
      }
    } else {
      if (nextIndex >= _currentQueue.length) {
        if (_repeatMode == PodRepeatMode.all) {
          nextIndex = 0;
        } else {
          _focusYield.noteUserPause();
          _intendPlay = false;
          await _engine.player?.stop();
          return;
        }
      }
    }
    await playSong(_currentQueue[nextIndex], queue: _currentQueue);
  }

  Future<void> playPrevious() async {
    if (_currentQueue.isEmpty) return;
    if ((_engine.player?.position.inSeconds ?? 0) > 3) {
      await _engine.player?.seek(Duration.zero);
      return;
    }

    int prevIndex = _currentQueueIndex - 1;
    if (prevIndex < 0) {
      prevIndex = _currentQueue.length - 1;
    }
    await playSong(_currentQueue[prevIndex], queue: _currentQueue);
  }

  Future<void> seek(Duration position) async {
    await _engine.player?.seek(position);
  }

  Future<int> getBatteryLevel() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final level = await _channel.invokeMethod<int>('getBatteryLevel');
        if (level != null && level >= 0 && level <= 100) return level;
      } catch (_) {}
    }
    if (!kIsWeb && Platform.isWindows) {
      // flutter test also runs on the Windows host; spawning powershell
      // there leaves dart:io timers pending and trips the test binding.
      if (Platform.environment['FLUTTER_TEST'] != 'true') {
        try {
          final result = await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            '(Get-CimInstance -ClassName Win32_Battery | Select-Object -First 1 -ExpandProperty EstimatedChargeRemaining)',
          ]);
          final parsed = int.tryParse(result.stdout.toString().trim());
          if (parsed != null && parsed >= 0 && parsed <= 100) return parsed;
          // No battery (desktop AC) — show full.
        } catch (_) {}
      }
      return 100;
    }
    return 100;
  }

  File? _findSidecarCover(Directory dir) {
    const names = [
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
      'folder.jpg',
      'folder.jpeg',
      'folder.png',
      'AlbumArt.jpg',
      'AlbumArt.jpeg',
      'front.jpg',
      'front.jpeg',
      'front.png',
    ];
    for (final name in names) {
      final f = File('${dir.path}\\$name');
      if (f.existsSync()) return f;
    }
    try {
      for (final entity in dir.listSync()) {
        if (entity is File) {
          final lower = entity.path
              .split(Platform.pathSeparator)
              .last
              .toLowerCase();
          if (lower.startsWith('albumart') &&
              (lower.endsWith('.jpg') ||
                  lower.endsWith('.jpeg') ||
                  lower.endsWith('.png'))) {
            return entity;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List?> getArtwork(int? albumId) async {
    if (albumId == null || albumId <= 0) return null;
    if (_artworkCache.containsKey(albumId)) {
      return _artworkCache[albumId];
    }

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final result = await _channel.invokeMethod<Uint8List>('getArtwork', {
          'albumId': albumId,
        });
        _artworkCache[albumId] = result;
        return result;
      } catch (_) {
        _artworkCache[albumId] = null;
        return null;
      }
    }

    if (!kIsWeb && Platform.isWindows) {
      final path = _albumArtPaths[albumId];
      if (path != null) {
        try {
          final file = File(path);
          if (file.existsSync()) {
            final bytes = await file.readAsBytes();
            _artworkCache[albumId] = bytes;
            return bytes;
          }
        } catch (_) {}
      }
    }

    _artworkCache[albumId] = null;
    return null;
  }

  Future<void> initVolume() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final double? v = await _channel.invokeMethod<double>('getVolume');
        if (v != null) {
          _volume = v.clamp(0.0, 1.0);
        }
      } catch (_) {}
    } else if (_engine.player != null) {
      _volume = _engine.player!.volume;
    }
  }

  Future<void> setVolume(double vol, {bool writeSystem = true}) async {
    _fadeEpoch++;
    _volume = vol.clamp(0.0, 1.0);
    try {
      // Loudness is the system music stream. Player volume stays at unity
      // so it is not a second attenuator.
      await _engine.player?.setVolume(1.0);
    } catch (_) {}
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod<dynamic>('setVolume', {
          'volume': _volume,
          'writeSystem': writeSystem,
        });
      } catch (_) {}
    }
  }

  void dispose() {
    _engine.dispose();
    _isInitialized = false;
  }
}
