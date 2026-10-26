import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Wheel ticks and center-button clicks.
///
/// Android plays these from a SoundPool on the music stream, so the tick
/// follows speaker, Bluetooth, and a USB DAC the mixer already selected.
/// The pool does not request audio focus. A media-player pool only survives
/// one `stop()` and then stays quiet, so each clip is loaded again.
class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  static const MethodChannel _channel = MethodChannel('com.likepod/media');

  /// Same −20 dB linear level as the Android SoundPool click.
  static const double clickVolume = 0.10;

  static final AudioContext _mixContext = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.none,
    ),
  );

  _ClipRing? _ticks;
  _ClipRing? _selects;
  Future<void>? _starting;

  Future<void> init() {
    return _starting ??= _load();
  }

  Future<void> _load() async {
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await _channel.invokeMethod<void>('prepareWheelSound');
      }
      _ticks = await _ClipRing.load('audio/tick.wav');
      _selects = await _ClipRing.load('audio/select.wav');
    } catch (e) {
      debugPrint('Click sounds failed to load: $e');
      _ticks = null;
      _selects = null;
      _starting = null;
    }
  }

  void _fallback(String asset) {
    final ring = asset == 'select' ? (_selects ?? _ticks) : _ticks;
    if (ring == null) {
      init().then((_) {
        final ready = asset == 'select' ? (_selects ?? _ticks) : _ticks;
        ready?.play();
      });
      return;
    }
    ring.play();
  }

  Future<void> _play(String kind) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final handled = await _channel.invokeMethod<bool>('playWheelSound', {
          'kind': kind,
        });
        if (handled == true) return;
      } catch (e) {
        debugPrint('Wheel sound channel failed: $e');
      }
    }
    _fallback(kind);
  }

  /// Short wheel tick while the click wheel is turning.
  void playTick({bool soundEnabled = true, bool hapticsEnabled = true}) {
    if (hapticsEnabled) {
      try {
        HapticFeedback.selectionClick();
      } catch (_) {}
    }
    if (soundEnabled) {
      unawaited(_play('tick'));
    }
  }

  /// Center-button click. Stays silent when click sounds are off.
  void playSelect({bool soundEnabled = true, bool hapticsEnabled = true}) {
    if (hapticsEnabled) {
      try {
        HapticFeedback.mediumImpact();
      } catch (_) {}
    }
    if (soundEnabled) {
      unawaited(_play('select'));
    }
  }

  void dispose() {
    _ticks?.dispose();
    _selects?.dispose();
    _ticks = null;
    _selects = null;
    _starting = null;
  }
}

/// A few prepared players. Completion stops the native player, so each clip
/// is loaded again and is ready for the next step.
class _ClipRing {
  _ClipRing._(this._asset);

  final String _asset;
  final List<AudioPlayer> _players = [];
  int _next = 0;

  static Future<_ClipRing> load(String asset) async {
    final ring = _ClipRing._(asset);
    for (var i = 0; i < 4; i++) {
      ring._players.add(await ring._create());
    }
    return ring;
  }

  Future<AudioPlayer> _create() async {
    final player = AudioPlayer();
    await player.setAudioContext(SoundService._mixContext);
    await player.setPlayerMode(PlayerMode.mediaPlayer);
    await player.setReleaseMode(ReleaseMode.stop);
    await player.setSource(AssetSource(_asset));
    player.onPlayerComplete.listen((_) {
      unawaited(_reload(player));
    });
    return player;
  }

  Future<void> _reload(AudioPlayer player) async {
    try {
      await player.setSource(AssetSource(_asset));
    } catch (e) {
      debugPrint('Click sound reload failed: $e');
    }
  }

  void play() {
    if (_players.isEmpty) return;
    final player = _players[_next];
    _next = (_next + 1) % _players.length;
    unawaited(_retrigger(player));
  }

  Future<void> _retrigger(AudioPlayer player) async {
    try {
      await player.seek(Duration.zero);
      await player.setVolume(SoundService.clickVolume);
      await player.resume();
    } catch (e) {
      debugPrint('Click sound failed: $e');
    }
  }

  void dispose() {
    for (final player in _players) {
      player.dispose();
    }
    _players.clear();
  }
}
