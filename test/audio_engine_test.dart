import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/audio_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.likepod/media_usb_test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('prefers a USB sink and clears it when the sink is gone', () async {
    var plugged = true;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'listOutputSinks') {
            return {
              'outputSampleRate': 48000,
              'sinks': plugged
                  ? [
                      {
                        'id': 1,
                        'name': 'phone',
                        'type': 2,
                        'sampleRates': [48000],
                        'encodings': [2],
                        'routed': false,
                      },
                      {
                        'id': 7,
                        'name': 'FiiO',
                        'type': 11,
                        'sampleRates': [44100, 48000],
                        'encodings': [2],
                        'routed': false,
                      },
                    ]
                  : [
                      {
                        'id': 1,
                        'name': 'phone',
                        'type': 2,
                        'sampleRates': [48000],
                        'encodings': [2],
                        'routed': true,
                      },
                    ],
            };
          }
          if (call.method == 'applyPreferredDevice') {
            return {'applied': plugged, 'mixerAccepted': false};
          }
          return null;
        });

    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    await engine.syncRoute();
    expect(engine.usingUsb, isTrue);
    expect(engine.snapshot.preferenceLine, '偏好设备：已设置');
    expect(engine.snapshot.routeLine, '路由：USB · FiiO');
    expect(engine.snapshot.currentOutputLine, contains('USB · 系统混音'));
    expect(
      calls
          .lastWhere((call) => call.method == 'applyPreferredDevice')
          .arguments,
      {'deviceId': 7, 'sampleRate': 0, 'force': false, 'highQuality': true},
    );

    plugged = false;
    calls.clear();
    await engine.syncRoute();
    expect(engine.usingUsb, isFalse);
    expect(engine.snapshot.routeLine, '路由：扬声器');
    expect(engine.snapshot.usbStatusLine, isNull);
    expect(engine.snapshot.via, '系统路径');
    expect(
      calls
          .lastWhere((call) => call.method == 'applyPreferredDevice')
          .arguments,
      {'deviceId': null, 'sampleRate': 0, 'force': false, 'highQuality': true},
    );
  });

  test('keeps the current route when USB cannot be selected', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listOutputSinks') {
            return {
              'outputSampleRate': 44100,
              'sinks': [
                {
                  'id': 1,
                  'name': 'phone',
                  'type': 2,
                  'sampleRates': [44100],
                  'encodings': [2],
                  'routed': true,
                },
                {
                  'id': 4,
                  'name': 'DAC',
                  'type': 11,
                  'sampleRates': [48000],
                  'encodings': [2],
                  'routed': false,
                },
              ],
            };
          }
          if (call.method == 'applyPreferredDevice') {
            return {'applied': false, 'mixerAccepted': false};
          }
          return null;
        });

    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    await engine.syncRoute();
    expect(engine.usingUsb, isFalse);
    expect(engine.snapshot.routeLine, '路由：扬声器');
    expect(engine.snapshot.usbStatusLine, 'USB 已连接：DAC，仍走当前路由');
    expect(engine.snapshot.preferenceLine, '偏好设备：失败 · 未返回原因');
    expect(engine.snapshot.preferenceLine, isNot(contains('比特完美')));
    expect(engine.snapshot.currentOutputLine, contains('系统路径'));
  });

  test('a device-change event refreshes the route', () async {
    var plugged = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listOutputSinks') {
            return {
              'outputSampleRate': 48000,
              'sinks': plugged
                  ? [
                      {
                        'id': 3,
                        'name': 'Headset',
                        'type': 22,
                        'sampleRates': [48000],
                        'encodings': [2],
                        'routed': true,
                      },
                    ]
                  : [
                      {
                        'id': 1,
                        'name': 'phone',
                        'type': 2,
                        'sampleRates': [48000],
                        'encodings': [2],
                        'routed': true,
                      },
                    ],
            };
          }
          if (call.method == 'applyPreferredDevice') {
            return {'applied': plugged, 'mixerAccepted': false};
          }
          return null;
        });

    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    engine.startListening();
    await engine.syncRoute();
    expect(engine.snapshot.routeLine, '路由：USB · Headset');

    plugged = false;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('onOutputDevicesChanged'),
          ),
          (_) {},
        );
    expect(engine.usingUsb, isFalse);
    expect(engine.snapshot.routeLine, '路由：扬声器');
  });

  test('a direct USB result replaces the system mix label', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listOutputSinks') {
            return {
              'outputSampleRate': 48000,
              'sinks': [
                {
                  'id': 1,
                  'name': 'phone',
                  'type': 2,
                  'sampleRates': [48000],
                  'encodings': [2],
                  'routed': true,
                },
              ],
            };
          }
          if (call.method == 'applyPreferredDevice') {
            return {
              'applied': true,
              'mixerAccepted': false,
              'directActive': true,
              'directRate': 44100,
              'directBitDepth': 16,
              'directResampled': false,
              'directDetail': '已打开 · 44.1kHz · 16-bit · UAC1',
              'directName': 'lifeme Hi-Fi Audio 3Pro',
              'directUi': 0.04,
              'directGain': 1 / 32768,
            };
          }
          return null;
        });

    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    engine.snapshot = engine.snapshot.copyWith(trackSampleRate: 44100);
    await engine.syncRoute();
    expect(engine.snapshot.via, 'USB · 直接输出');
    expect(engine.snapshot.routeLine, '路由：USB · lifeme Hi-Fi Audio 3Pro');
    expect(engine.snapshot.directLine, contains('已打开'));
    expect(engine.snapshot.softwareGainLine, '软件音量：4% → −90 dB');
    expect(engine.snapshot.currentOutputLine, contains('44.1kHz'));
    expect(engine.snapshot.currentOutputLine, isNot(contains('比特完美')));

    var heard = -1.0;
    engine.onAppliedGain = (gain) {
      heard = gain;
    };
    engine.startListening();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('onDirectGain', {'ui': 0.08, 'linear': 4 / 32768}),
          ),
          (_) {},
        );
    expect(engine.snapshot.softwareGainLine, contains('8%'));
    expect(engine.snapshot.softwareGainLine, contains('dB'));
    expect(engine.snapshot.softwareGainLine, isNot(contains('（线性）')));
    expect(heard, closeTo(0.08, 0.001));
  });
}
