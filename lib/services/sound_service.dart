import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  AudioPlayer? _clickPlayer;
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      _clickPlayer = AudioPlayer();
      await _clickPlayer!.setReleaseMode(ReleaseMode.stop);
      // Low latency mode for sound effects
      await _clickPlayer!.setPlayerMode(PlayerMode.lowLatency);
      await _clickPlayer!.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
      ));
      await _clickPlayer!.setSource(AssetSource('audio/click.wav'));
      _isInitialized = true;
    } catch (e) {
      // If audio player fails on specific desktop platforms, gracefully fallback
      _isInitialized = false;
    }
  }

  void playClick({bool soundEnabled = true, bool hapticsEnabled = true}) {
    // 1. Tactile haptic feedback
    if (hapticsEnabled) {
      try {
        HapticFeedback.selectionClick();
      } catch (_) {}
    }

    // 2. Audible mechanical click sound
    if (soundEnabled && _clickPlayer != null) {
      try {
        _clickPlayer!.seek(Duration.zero).then((_) {
          _clickPlayer!.resume();
        }).catchError((_) {
          _clickPlayer!.play(AssetSource('audio/click.wav'));
        });
      } catch (_) {}
    }
  }

  void playConfirm({bool soundEnabled = true, bool hapticsEnabled = true}) {
    if (hapticsEnabled) {
      try {
        HapticFeedback.mediumImpact();
      } catch (_) {}
    }
    if (soundEnabled && _clickPlayer != null) {
      playClick(soundEnabled: soundEnabled, hapticsEnabled: false);
    }
  }

  void dispose() {
    _clickPlayer?.dispose();
    _isInitialized = false;
  }
}
