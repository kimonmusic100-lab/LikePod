import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'focus_route.dart';
import 'output_probe.dart';

/// just_audio playback plus output probing.
///
/// Background controls stay on audio_service. This class does not start a
/// second media session.
///
/// When a USB DAC is attached, [syncRoute] asks Android to open a direct
/// isochronous stream at the track rate. If that fails, the player still
/// prefers the USB device and may ask for a no-resample mixer. Neither
/// fallback is treated as verified bit-identical audio.
class AudioEngine {
  AudioEngine({MethodChannel? channel, bool? routeOnThisPlatform})
    : _channel = channel ?? const MethodChannel('com.likepod/media'),
      _routeHere = routeOnThisPlatform ?? (!kIsWeb && Platform.isAndroid);

  final MethodChannel _channel;
  final bool _routeHere;
  AudioPlayer? _player;

  /// High quality claims the USB DAC exclusively; standard stays on the
  /// system mixer. Set from the saved quality mode before the first scan.
  bool highQualityOutput = true;
  OutputSnapshot snapshot = OutputSnapshot.unknown;
  void Function()? onSnapshot;

  /// Fired with the UI position that is limiting the direct path.
  void Function(double ui)? onAppliedGain;

  /// Another app took audio focus. The native side already paused and
  /// released the USB interface.
  void Function()? onFocusLost;

  /// The direct stream died while playback intent remained (freeze stall).
  void Function()? onDirectDied;

  bool playerPlaying() {
    try {
      return _player?.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Focus returned. [resume] is true when LikePod was playing before the loss.
  Future<void> Function(bool resume)? onFocusGained;
  bool _listening = false;

  AudioPlayer? get player => _player;
  bool get hasPlayer => _player != null;

  /// True when the snapshot is describing a USB sink.
  bool get usingUsb => snapshot.usbPreferred;

  bool get routesOnDevice => _routeHere;

  /// One later read after playback starts, so a track created during play
  /// can report where it actually went.
  void recheckUsbRoute() {
    if (!_routeHere) return;
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      syncRoute(force: true);
    });
  }

  /// Re-opens the direct stream shortly after its death. A process freeze
  /// (HyperOS) kills the isochronous thread while the dongle stays claimed;
  /// three quick retries catch the unfreeze without waiting for another
  /// route event. A physical drop keeps failing here cheaply and is
  /// handled by the attach event instead.
  void retryDirectAfterDeath() {
    if (!_routeHere) return;
    for (final delay in const [300, 900, 2000]) {
      Future<void>.delayed(Duration(milliseconds: delay), () {
        if (!snapshot.usbPreferred || snapshot.directActive) return;
        syncRoute(force: true);
      });
    }
  }

  bool ensurePlayer() {
    if (_player != null) return true;
    try {
      _player = AudioPlayer(
        handleInterruptions: false,
        // play() must not call AudioSession.setActive. That is a second
        // AUDIOFOCUS_GAIN, and the focus listener treats it as another app:
        // it pauses playback and releases the USB DAC.
        handleAudioSessionActivation: false,
        audioPipeline: AudioPipeline(),
      );
      return true;
    } catch (e) {
      debugPrint('AudioPlayer unavailable: $e');
      return false;
    }
  }

  /// Listens for USB attach and detach. Safe to call more than once.
  void startListening() {
    if (_listening || !_routeHere) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onOutputDevicesChanged') {
        await syncRoute();
      } else if (call.method == 'onDirectGain') {
        noteDirectReport(call.arguments);
      } else if (call.method == 'onBackgroundPath') {
        final path = call.arguments;
        noteBackgroundPath(path is String ? path : '');
      } else if (call.method == 'onAudioFocusLost') {
        if (releaseExclusiveOnFocus('loss')) onFocusLost?.call();
      } else if (call.method == 'onAudioFocusGained') {
        final resume = call.arguments == true;
        final gained = onFocusGained;
        if (gained != null) await gained(resume);
      }
    });
  }

  Future<void> refreshRoute() => syncRoute();

  /// Records the UI position and the PCM amplitude the direct path is using.
  void noteAppliedGain({required double ui, required double linear}) {
    if (!snapshot.directActive) return;
    final safeUi = ui.clamp(0.0, 1.0);
    final safeLinear = linear.clamp(0.0, 1.0);
    snapshot = snapshot.copyWith(directUi: safeUi, directGain: safeLinear);
    onAppliedGain?.call(safeUi);
    onSnapshot?.call();
  }

  void noteBackgroundPath(String path) {
    if (path != 'direct' && path != 'mixer' && path.isNotEmpty) return;
    snapshot = snapshot.copyWith(backgroundPath: path);
    onSnapshot?.call();
  }

  void noteDirectReport(Object? raw) {
    if (raw is! Map) return;
    final ui = raw['ui'];
    final linear = raw['linear'];
    if (ui is num && linear is num) {
      noteAppliedGain(ui: ui.toDouble(), linear: linear.toDouble());
    }
  }

  /// Re-reads output devices and points the player at a USB sink when one
  /// exists. A missing player returns applied=false; the next track open
  /// retries. Unplug clears the preference and does not stop playback.
  Future<void> syncRoute({bool force = false}) async {
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
      final sinks = _parseSinks(map['sinks']);
      final usb = chooseUsbSink(sinks);
      final trackRate = snapshot.trackSampleRate;
      final pref = await _channel.invokeMethod<dynamic>(
        'applyPreferredDevice',
        {
          'deviceId': usb?.id,
          'sampleRate': usb != null && trackRate != null && trackRate > 0
              ? trackRate
              : 0,
          'force': force,
          'highQuality': highQualityOutput,
        },
      );
      var applied = false;
      var mixerAccepted = false;
      var mixerBitPerfect = false;
      var directActive = false;
      var directResampled = false;
      var directRate = 0;
      var directBitDepth = 0;
      var directDetail = '';
      var directName = '';
      var directGain = -1.0;
      var directUi = -1.0;
      var backgroundMixer = false;
      var backgroundPath = '';
      String? rawDetail;
      if (pref is Map) {
        final prefMap = Map<Object?, Object?>.from(pref);
        applied = prefMap['applied'] == true;
        mixerAccepted = prefMap['mixerAccepted'] == true;
        mixerBitPerfect = prefMap['mixerBitPerfect'] == true;
        directActive = prefMap['directActive'] == true;
        directResampled = prefMap['directResampled'] == true;
        directRate = _asInt(prefMap['directRate']) ?? 0;
        directBitDepth = _asInt(prefMap['directBitDepth']) ?? 0;
        final rawDirect = prefMap['directDetail'];
        if (rawDirect is String) directDetail = rawDirect;
        final rawName = prefMap['directName'];
        if (rawName is String) directName = rawName;
        final rawGain = prefMap['directGain'];
        if (rawGain is num) directGain = rawGain.toDouble();
        final rawUi = prefMap['directUi'];
        if (rawUi is num) directUi = rawUi.toDouble();
        backgroundMixer = prefMap['backgroundMixer'] == true;
        final rawBackground = prefMap['backgroundPath'];
        if (rawBackground is String) backgroundPath = rawBackground;
        final detail = prefMap['detail'];
        if (detail is String) rawDetail = detail;
      }
      final verified = pref is Map && pref['verifiedUsb'] == true;
      final directDead = snapshot.usbPreferred &&
          !directActive &&
          playerPlaying() &&
          highQualityOutput;
      if (directDead) {
        onDirectDied?.call();
      }
      snapshot = describeRoute(
        sinks: sinks,
        outputSampleRate: _asInt(map['outputSampleRate']),
        preferredApplied: applied || verified || directActive,
        mixerAccepted: mixerAccepted,
        trackSampleRate: snapshot.trackSampleRate,
        trackBitDepth: snapshot.trackBitDepth,
        preferenceDetail: directActive
            ? ''
            : _preferenceDetail(
                usb: usb,
                applied: applied || verified,
                raw: rawDetail,
              ),
        directActive: directActive,
        directRate: directRate,
        directBitDepth: directBitDepth,
        directResampled: directResampled,
        directDetail: directDetail,
        directName: directName,
        mixerBitPerfect: mixerBitPerfect,
        directGain: directGain,
        directUi: directUi,
        backgroundMixer: backgroundMixer,
        backgroundPath: backgroundPath,
      );
    } catch (e) {
      debugPrint('Output route sync failed: $e');
    }
    onSnapshot?.call();
  }

  /// Reads file metadata after the track is already open in just_audio.
  /// Re-applies the USB device afterwards, because opening a track can
  /// rebuild the audio sink.
  Future<void> noteTrack(String uri) async {
    if (!_routeHere || uri.startsWith('asset:///')) {
      snapshot = snapshot.copyWith(clearTrack: true);
      await syncRoute();
      return;
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('probeTrack', {
        'uri': uri,
      });
      if (raw is Map) {
        final map = Map<Object?, Object?>.from(raw);
        snapshot = snapshot.copyWith(
          clearTrack: true,
          trackSampleRate: _asInt(map['sampleRate']),
          trackBitDepth: _asInt(map['bitDepth']),
        );
      }
    } catch (e) {
      debugPrint('Track probe failed: $e');
    }
    await syncRoute();
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

String _preferenceDetail({
  required AudioSink? usb,
  required bool applied,
  required String? raw,
}) {
  if (usb == null) return '';
  final text = raw?.trim() ?? '';
  if (text.isNotEmpty) return text;
  return applied ? '已设置' : '失败 · 未返回原因';
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
