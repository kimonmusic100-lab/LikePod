import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import 'wave_style.dart';

/// True when a capture frame has enough energy to be visible.
bool spectrumLooksLive(List<double> levels) {
  var peak = 0.0;
  for (final level in levels) {
    if (level > peak) peak = level;
  }
  return peak >= 0.05;
}

/// Live band levels from the track that is actually playing.
///
/// The player's own audio session is attached first, with no permission
/// dialog. If that capture stays silent or is refused, and the app is in
/// front, one microphone prompt is shown and the output mix is tried.
class SpectrumFeed {
  SpectrumFeed._();

  static final SpectrumFeed instance = SpectrumFeed._();

  static const _method = MethodChannel('com.likepod/spectrum');
  static const _events = EventChannel('com.likepod/spectrum_events');

  final ValueNotifier<List<double>> levels = ValueNotifier<List<double>>(
    List<double>.filled(spectrumBandCount, 0),
  );

  StreamSubscription<dynamic>? _subscription;
  Timer? _watch;
  int? _session;
  int _generation = 0;
  bool _askedPermission = false;
  bool _triedMix = false;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _ensureListening() {
    if (_subscription != null) return;
    _subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! List) return;
        final target = <double>[
          for (final value in event)
            if (value is num) value.toDouble() else 0.0,
        ];
        levels.value = smoothSpectrum(levels.value, target);
      },
      onError: (Object error) {
        unawaited(_log('wave stream fail $error'));
      },
    );
  }

  /// [sessionId] is this player's session. Null waits. [promptIfSilent] asks
  /// for capture permission when Now Playing is open and the bands stay flat.
  Future<void> follow(
    int? sessionId, {
    required bool playing,
    bool promptIfSilent = false,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (!playing) {
      _generation++;
      _watch?.cancel();
      await stop();
      return;
    }
    _ensureListening();
    final id = sessionId;
    if (id == null || id <= 0) {
      await _log('wave waiting for session');
      return;
    }
    if (_session == id && !promptIfSilent) return;
    if (_session != id) {
      final status = await _start(id);
      if (status != 'ok') {
        await _escalate(id, prompt: promptIfSilent && _foreground);
        return;
      }
    }
    _scheduleCheck(id, prompt: promptIfSilent && _foreground);
  }

  void _scheduleCheck(int sessionId, {required bool prompt}) {
    final generation = ++_generation;
    _watch?.cancel();
    _watch = Timer(const Duration(milliseconds: 450), () async {
      if (generation != _generation) return;
      if (spectrumLooksLive(levels.value)) {
        await _log('wave live sessionId=$sessionId');
        return;
      }
      await _start(sessionId, force: true);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (generation != _generation) return;
      if (spectrumLooksLive(levels.value)) {
        await _log('wave live sessionId=$sessionId');
        return;
      }
      await _log('wave silent sessionId=$sessionId');
      await _escalate(sessionId, prompt: prompt);
    });
  }

  Future<void> _escalate(int sessionId, {required bool prompt}) async {
    final generation = _generation;
    if (!_askedPermission) {
      if (!prompt || !_foreground) {
        await _log('wave needs permission, waiting for Now Playing');
        return;
      }
      _askedPermission = true;
      await _log('wave permission request');
      final granted = await Permission.microphone.request();
      if (generation != _generation) return;
      await _log(
        granted.isGranted
            ? 'wave permission granted'
            : 'wave permission denied',
      );
      if (!granted.isGranted) return;
    } else if (!await Permission.microphone.isGranted) {
      return;
    }
    if (generation != _generation) return;
    final retry = await _start(sessionId, force: true);
    await _log('wave retry sessionId=$sessionId $retry');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (generation != _generation) return;
    if (spectrumLooksLive(levels.value) || _triedMix) return;
    _triedMix = true;
    final mix = await _start(0, force: true);
    await _log('wave attach sessionId=0 $mix');
  }

  Future<String> _start(int sessionId, {bool force = false}) async {
    try {
      if (force) {
        await _method.invokeMethod<bool>('stop');
        _session = null;
      }
      final result = await _method.invokeMethod<String>('start', {
        'sessionId': sessionId,
      });
      if (result == 'ok') _session = sessionId;
      return result ?? 'unavailable';
    } catch (error) {
      await _log('wave attach sessionId=$sessionId fail $error');
      return 'unavailable';
    }
  }

  Future<void> stop() async {
    if (_session == null) return;
    _session = null;
    try {
      await _method.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  Future<void> _log(String message) async {
    debugPrint(message);
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _method.invokeMethod<bool>('log', {'message': message});
    } catch (_) {}
  }

  /// Widget tests paint a measured frame without a device visualizer.
  void debugSetLevels(List<double> next) {
    final padded = List<double>.filled(spectrumBandCount, 0);
    for (var i = 0; i < spectrumBandCount && i < next.length; i++) {
      padded[i] = next[i].clamp(0.0, 1.0);
    }
    levels.value = padded;
  }
}
