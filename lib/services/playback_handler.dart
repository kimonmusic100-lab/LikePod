import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../models/song_model.dart';
import 'music_service.dart';

/// Starts the Android foreground media service used for background playback.
///
/// The service shows a media notification (previous / play-pause / next) and
/// publishes lock-screen metadata. Desktop and tests skip this; playback still
/// uses [MusicService]'s [ja.AudioPlayer].
class PlaybackBootstrap {
  static Future<void> start() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await AudioService.init(
        builder: PodAudioHandler.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.likepod.likepod.channel.audio',
          androidNotificationChannelName: 'LikePod 播放',
          androidNotificationChannelDescription: '后台播放、锁屏与通知栏控制',
          // Keep the foreground service up while paused so notification
          // play/pause works on Android 12+ without restarting the service.
          // audio_service rejects ongoing=true together with this flag.
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          androidNotificationClickStartsActivity: true,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      );
    } catch (e) {
      debugPrint('AudioService init failed: $e');
    }
  }
}

class PodAudioHandler extends BaseAudioHandler with SeekHandler {
  PodAudioHandler() {
    final music = MusicService();
    if (!music.ensurePlayer()) return;
    final player = music.player;
    player.playbackEventStream.listen(
      (_) => _broadcast(),
      onError: (Object e, StackTrace st) {
        debugPrint('playback event error: $e');
      },
    );
    player.playerStateStream.listen((_) => _broadcast());
    _broadcast();
  }

  String? _publishedId;
  Duration? _publishedDuration;

  void _broadcast() {
    final music = MusicService();
    if (!music.hasPlayer) return;
    final player = music.player;
    final song = music.currentSong;
    if (song != null) {
      final item = _mediaItemFor(song, player.duration);
      if (_publishedId != item.id || _publishedDuration != item.duration) {
        _publishedId = item.id;
        _publishedDuration = item.duration;
        mediaItem.add(item);
      }
    }

    final playing = player.playing;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _mapState(player.processingState),
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: music.queueIndex >= 0 ? music.queueIndex : null,
        repeatMode: _mapRepeat(music.repeatMode),
        shuffleMode: music.shuffleMode == PodShuffleMode.songs
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  MediaItem _mediaItemFor(SongModel song, Duration? duration) {
    Uri? artUri;
    final albumId = song.albumId;
    if (!kIsWeb && Platform.isAndroid && albumId != null && albumId > 0) {
      artUri = Uri.parse('content://media/external/audio/albumart/$albumId');
    }
    return MediaItem(
      id: '${song.id}',
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: duration ?? Duration(milliseconds: song.durationMs),
      artUri: artUri,
    );
  }

  AudioProcessingState _mapState(ja.ProcessingState state) {
    switch (state) {
      case ja.ProcessingState.idle:
        return AudioProcessingState.idle;
      case ja.ProcessingState.loading:
        return AudioProcessingState.loading;
      case ja.ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ja.ProcessingState.ready:
        return AudioProcessingState.ready;
      case ja.ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  AudioServiceRepeatMode _mapRepeat(PodRepeatMode mode) {
    switch (mode) {
      case PodRepeatMode.off:
        return AudioServiceRepeatMode.none;
      case PodRepeatMode.all:
        return AudioServiceRepeatMode.all;
      case PodRepeatMode.one:
        return AudioServiceRepeatMode.one;
    }
  }

  @override
  Future<void> play() => MusicService().resume();

  @override
  Future<void> pause() => MusicService().pause();

  @override
  Future<void> seek(Duration position) => MusicService().seek(position);

  @override
  Future<void> skipToNext() => MusicService().playNext();

  @override
  Future<void> skipToPrevious() => MusicService().playPrevious();

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final PodRepeatMode mode;
    switch (repeatMode) {
      case AudioServiceRepeatMode.one:
        mode = PodRepeatMode.one;
        break;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        mode = PodRepeatMode.all;
        break;
      case AudioServiceRepeatMode.none:
        mode = PodRepeatMode.off;
        break;
    }
    MusicService().setRepeatMode(mode);
    _broadcast();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    MusicService().setShuffleMode(
      shuffleMode == AudioServiceShuffleMode.none ? PodShuffleMode.off : PodShuffleMode.songs,
    );
    _broadcast();
  }
}
