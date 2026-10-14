import 'dart:io';
import 'dart:math';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/song_model.dart';

enum PodShuffleMode {
  off,
  songs,
}

enum PodRepeatMode {
  off,
  all,
  one,
}

class MusicService {
  static final MusicService _instance = MusicService._internal();
  factory MusicService() => _instance;
  MusicService._internal();

  static const MethodChannel _channel = MethodChannel('com.likepod/media');
  final AudioPlayer _player = AudioPlayer();

  final Map<int, Uint8List?> _artworkCache = {};
  /// Windows/desktop: albumId -> sidecar cover file path.
  final Map<int, String> _albumArtPaths = {};
  List<SongModel> _allSongs = [];
  List<SongModel> _currentQueue = [];
  int _currentQueueIndex = -1;

  PodShuffleMode _shuffleMode = PodShuffleMode.off;
  PodRepeatMode _repeatMode = PodRepeatMode.all;

  double _volume = 0.7;
  bool _isInitialized = false;

  AudioPlayer get player => _player;
  List<SongModel> get allSongs => _allSongs;
  double get volume => _volume;
  PodShuffleMode get shuffleMode => _shuffleMode;
  PodRepeatMode get repeatMode => _repeatMode;
  int get queueLength => _currentQueue.length;
  int get queueIndex => _currentQueueIndex;
  SongModel? get currentSong =>
      (_currentQueueIndex >= 0 && _currentQueueIndex < _currentQueue.length)
          ? _currentQueue[_currentQueueIndex]
          : null;

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    await initVolume();

    // Configure AudioSession for uninterrupted background music playback
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      await session.setActive(true);
    } catch (e) {
      debugPrint('Error configuring AudioSession: $e');
    }

    _player.playbackEventStream.listen(
      (event) {},
      onError: (Object e, StackTrace st) {
        debugPrint('JustAudio playbackEvent error: $e');
      },
    );

    // Auto next track only on true completion
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        final pos = _player.position.inSeconds;
        final dur = _player.duration?.inSeconds ?? 0;
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
                  final filename = file.uri.pathSegments.last.replaceAll('.$ext', '');
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

    if (songs.isEmpty) {
      songs.addAll(_getSamplePlayableTracks());
    }

    _allSongs = songs;
    return songs;
  }

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

  Future<void> playSong(SongModel song, {List<SongModel>? queue}) async {
    if (queue != null && queue.isNotEmpty) {
      _currentQueue = List.from(queue);
    } else if (!_currentQueue.contains(song)) {
      _currentQueue = [song];
    }

    _currentQueueIndex = _currentQueue.indexOf(song);

    try {
      try {
        final session = await AudioSession.instance;
        await session.setActive(true);
      } catch (_) {}

      if (song.uri.startsWith('asset:///')) {
        final assetPath = song.uri.replaceFirst('asset:///', '');
        await _player.setAsset(assetPath);
      } else if (File(song.uri).existsSync()) {
        await _player.setFilePath(song.uri);
      } else if (song.uri.startsWith('content://') || song.uri.startsWith('file://')) {
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(song.uri)),
          preload: true,
        );
      } else {
        await _player.setFilePath(song.uri);
      }
      await _player.play();
    } catch (e) {
      debugPrint('Error playing song ${song.title}: $e');
    }
  }

  Future<void> togglePlayPause() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      if (currentSong == null && _allSongs.isNotEmpty) {
        await playSong(_allSongs.first, queue: _allSongs);
      } else {
        await _player.play();
      }
    }
  }

  void setShuffleMode(PodShuffleMode mode) {
    _shuffleMode = mode;
  }

  void setRepeatMode(PodRepeatMode mode) {
    _repeatMode = mode;
  }

  void toggleShuffle() {
    _shuffleMode = _shuffleMode == PodShuffleMode.off
        ? PodShuffleMode.songs
        : PodShuffleMode.off;
  }

  void toggleRepeat() {
    switch (_repeatMode) {
      case PodRepeatMode.off:
        _repeatMode = PodRepeatMode.all;
        break;
      case PodRepeatMode.all:
        _repeatMode = PodRepeatMode.one;
        break;
      case PodRepeatMode.one:
        _repeatMode = PodRepeatMode.off;
        break;
    }
  }

  Future<void> shuffleAndPlayAll() async {
    if (_allSongs.isEmpty) return;
    final list = List<SongModel>.from(_allSongs)..shuffle();
    _shuffleMode = PodShuffleMode.songs;
    await playSong(list.first, queue: list);
  }

  Future<void> playNext() async {
    if (_currentQueue.isEmpty) return;

    if (_repeatMode == PodRepeatMode.one) {
      await seek(Duration.zero);
      await _player.play();
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
          await _player.stop();
          return;
        }
      }
    }
    await playSong(_currentQueue[nextIndex], queue: _currentQueue);
  }

  Future<void> playPrevious() async {
    if (_currentQueue.isEmpty) return;
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }

    int prevIndex = _currentQueueIndex - 1;
    if (prevIndex < 0) {
      prevIndex = _currentQueue.length - 1;
    }
    await playSong(_currentQueue[prevIndex], queue: _currentQueue);
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }


  Future<int> getBatteryLevel() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final level = await _channel.invokeMethod<int>('getBatteryLevel');
        if (level != null && level >= 0 && level <= 100) return level;
      } catch (_) {}
    }
    if (!kIsWeb && Platform.isWindows) {
      try {
        final result = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-Command',
            '(Get-CimInstance -ClassName Win32_Battery | Select-Object -First 1 -ExpandProperty EstimatedChargeRemaining)'
          ],
        );
        final parsed = int.tryParse(result.stdout.toString().trim());
        if (parsed != null && parsed >= 0 && parsed <= 100) return parsed;
        // No battery (desktop AC) — show full.
        return 100;
      } catch (_) {
        return 100;
      }
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
          final lower = entity.path.split(Platform.pathSeparator).last.toLowerCase();
          if (lower.startsWith('albumart') &&
              (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png'))) {
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
        final result = await _channel.invokeMethod<Uint8List>('getArtwork', {'albumId': albumId});
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
    } else {
      _volume = _player.volume;
    }
  }

  Future<void> setVolume(double vol) async {
    _volume = vol.clamp(0.0, 1.0);
    try {
      await _player.setVolume(_volume);
    } catch (_) {}
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('setVolume', {'volume': _volume});
      } catch (_) {}
    }
  }

  void dispose() {
    _player.dispose();
  }
}
