import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/audio_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.likepod/media_route_test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reports the routed sink and does not request a USB device', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
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
                  'routed': false,
                },
                {
                  'id': 7,
                  'name': 'FiiO',
                  'type': 11,
                  'sampleRates': [44100, 48000],
                  'encodings': [2],
                  'routed': true,
                },
              ],
            };
          }
          return null;
        });

    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    await engine.syncRoute();
    expect(engine.usingUsb, isTrue);
    expect(engine.snapshot.routeLine, '路由：USB · FiiO');
    expect(engine.snapshot.via, 'USB · 系统混音');
    expect(engine.snapshot.currentOutputLine, contains('系统混音'));
    expect(engine.snapshot.currentOutputLine, isNot(contains('直接')));
    expect(engine.snapshot.currentOutputLine, isNot(contains('比特完美')));
    expect(calls.map((call) => call.method), ['listOutputSinks']);
    expect(calls.map((call) => call.method), isNot(contains('applyPreferredDevice')));
  });

  test('an idle USB sink leaves the routed speaker in place', () async {
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
          return null;
        });

    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    await engine.syncRoute();
    expect(engine.usingUsb, isFalse);
    expect(engine.snapshot.usbConnected, isTrue);
    expect(engine.snapshot.routeLine, '路由：扬声器');
    expect(engine.snapshot.via, '系统路径');
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
                        'type': 8,
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
          return null;
        });

    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    engine.startListening();
    await engine.syncRoute();
    expect(engine.snapshot.routeLine, '路由：蓝牙');

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

  test('focus loss notifies the listener and focus gain does not resume', () async {
    var lost = 0;
    final engine = AudioEngine(channel: channel, routeOnThisPlatform: true);
    engine.onFocusLost = () {
      lost += 1;
    };
    engine.startListening();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onAudioFocusLost'),
      ),
      (_) {},
    );
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onAudioFocusGained', true),
      ),
      (_) {},
    );
    expect(lost, 1);
  });
}
