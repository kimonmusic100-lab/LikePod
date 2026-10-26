import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'wave_style.dart';

/// Live band levels from the track that is actually playing.
///
/// Android Visualizer is attached to this app's own audio session. A capture
/// permission is requested only after that attach is refused. When the
/// visualizer cannot run, the last real frame stays put. Nothing is invented.
class SpectrumFeed {
  SpectrumFeed._();

  static final SpectrumFeed instance = SpectrumFeed._();

  static const _method = MethodChannel('com.likepod/spectrum');
  static const _events = EventChannel('com.likepod/spectrum_events');

  final ValueNotifier<List<double>> levels = ValueNotifier<List<double>>(
    List<double>.filled(spectrumBandCount, 0),
  );

  StreamSubscription<dynamic>? _subscription;
  int? _session;
  bool _askedPermission = false;

  void _ensureListening() {
    if (_subscription != null) return;
    _subscription = _events.receiveBroadcastStream().listen((event) {
      if (event is! List) return;
      final target = <double>[
        for (final value in event)
          if (value is num) value.toDouble() else 0.0,
      ];
      levels.value = smoothSpectrum(levels.value, target);
    }, onError: (Object _) {});
  }

  /// [sessionId] is the playing track's session. Zero and null are ignored.
  Future<void> follow(int? sessionId, {required bool playing}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (!playing || sessionId == null || sessionId <= 0) {
      await stop();
      return;
    }
    if (_session == sessionId) return;
    _ensureListening();
    final status = await _start(sessionId);
    if (status == 'permission' && !_askedPermission) {
      _askedPermission = true;
      final granted = await Permission.microphone.request();
      if (granted.isGranted) {
        await _start(sessionId);
      }
    }
  }

  Future<String> _start(int sessionId) async {
    try {
      final result = await _method.invokeMethod<String>('start', {
        'sessionId': sessionId,
      });
      if (result == 'ok') _session = sessionId;
      return result ?? 'unavailable';
    } catch (_) {
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

  /// Widget tests paint a measured frame without a device visualizer.
  void debugSetLevels(List<double> next) {
    final padded = List<double>.filled(spectrumBandCount, 0);
    for (var i = 0; i < spectrumBandCount && i < next.length; i++) {
      padded[i] = next[i].clamp(0.0, 1.0);
    }
    levels.value = padded;
  }
}
