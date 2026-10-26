import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'output_probe.dart';

/// just_audio playback on the system mixer.
///
/// Background controls stay on audio_service. This class does not start a
/// second media session and does not claim a USB interface. A USB DAC is
/// heard only when Android has already routed the music stream to it.
class AudioEngine {
  AudioEngine({MethodChannel? channel, bool? routeOnThisPlatform})
    : _channel = channel ?? const MethodChannel('com.likepod/media'),
      _routeHere = routeOnThisPlatform ?? (!kIsWeb && Platform.isAndroid);

  final MethodChannel _channel;
  final bool _routeHere;
  AudioPlayer? _player;

  OutputSnapshot snapshot = OutputSnapshot.unknown;
  void Function()? onSnapshot;

  /// Another app took audio focus. Pause without dropping the focus request.
  void Function()? onFocusLost;

  /// The interrupting app released focus. Resume only a yield pause.
  void Function()? onFocusGained;

  bool playerPlaying() {
    try {
      return _player?.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  bool _listening = false;

  AudioPlayer? get player => _player;
  bool get hasPlayer => _player != null;

  /// True when Android is already routing media to a USB sink.
  bool get usingUsb => snapshot.usbRouted;

  bool get routesOnDevice => _routeHere;

  bool ensurePlayer() {
    if (_player != null) return true;
    try {
      _player = AudioPlayer(
        handleInterruptions: false,
        // play() must not call AudioSession.setActive. That is a second
        // AUDIOFOCUS_GAIN, and the focus listener treats it as another app.
        handleAudioSessionActivation: false,
        audioPipeline: AudioPipeline(),
      );
      return true;
    } catch (e) {
      debugPrint('AudioPlayer unavailable: $e');
      return false;
    }
  }

  /// Listens for output-device changes and focus loss. Safe to call more than once.
  void startListening() {
    if (_listening || !_routeHere) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOutputDevicesChanged') {
        await syncRoute();
      } else if (call.method == 'onAudioFocusLost') {
        onFocusLost?.call();
      } else if (call.method == 'onAudioFocusGained') {
        onFocusGained?.call();
      }
    });
  }

  Future<void> refreshRoute() => syncRoute();

  /// Re-reads output devices. Does not ask Android to prefer a USB sink.
  Future<void> syncRoute() async {
    if (!_routeHere) {
      onSnapshot?.call();
      return;
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('listOutputSinks');
      if (raw is! Map) {
        onSnapshot?.call();
        return;
      }
      final map = Map<Object?, Object?>.from(raw);
      snapshot = describeRoute(
        sinks: _parseSinks(map['sinks']),
        outputSampleRate: _asInt(map['outputSampleRate']),
      );
    } catch (e) {
      debugPrint('Output route sync failed: $e');
    }
    onSnapshot?.call();
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

List<int> _asIntList(Object? value) {
  if (value is! List) return const [];
  final rates = <int>[];
  for (final item in value) {
    final rate = _asInt(item);
    if (rate != null && rate > 0) rates.add(rate);
  }
  return rates;
}

List<AudioSink> _parseSinks(Object? value) {
  if (value is! List) return const [];
  final sinks = <AudioSink>[];
  for (final item in value) {
    if (item is! Map) continue;
    final map = Map<Object?, Object?>.from(item);
    final id = _asInt(map['id']);
    final type = _asInt(map['type']);
    if (id == null || type == null) continue;
    sinks.add(
      AudioSink(
        id: id,
        name: map['name'] as String? ?? '',
        kind: kindFromAndroidType(type),
        sampleRates: _asIntList(map['sampleRates']),
        encodings: _asIntList(map['encodings']),
        routed: map['routed'] == true,
      ),
    );
  }
  return sinks;
}
