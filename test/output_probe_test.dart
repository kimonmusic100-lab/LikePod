import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/output_probe.dart';

void main() {
  test('formats a known system rate and bit depth without a bit-perfect claim', () {
    final line = formatCurrentOutput(sampleRate: 44100, bitDepth: 16);
    expect(line, '当前输出：44.1kHz / 16-bit（系统路径）');
    expect(line.toLowerCase(), isNot(contains('bit-perfect')));
    expect(line, isNot(contains('比特完美')));
    expect(line, isNot(contains('独占')));
  });

  test('does not invent a rate or depth when the probe is empty', () {
    const snapshot = OutputSnapshot.unknown;
    expect(snapshot.currentOutputLine, '当前输出：采样率未报告 / 位深未报告（系统路径）');
    expect(snapshot.brief, '未报告');
    expect(snapshot.routeLine, '路由：未报告');
    expect(snapshot.usbRouted, isFalse);
  });

  test('USB accessory is not a DAC and a headset outranks a USB device', () {
    expect(kindFromAndroidType(androidTypeUsbHeadset), AudioSinkKind.usbHeadset);
    expect(kindFromAndroidType(androidTypeUsbDevice), AudioSinkKind.usbDevice);
    expect(kindFromAndroidType(androidTypeUsbAccessory), AudioSinkKind.other);
    expect(kindFromAndroidType(androidTypeBuiltinSpeaker), AudioSinkKind.speaker);

    final chosen = chooseUsbSink([
      _sink(id: 4, kind: AudioSinkKind.other, name: 'accessory'),
      _sink(id: 9, kind: AudioSinkKind.usbDevice, name: 'late-dac'),
      _sink(id: 3, kind: AudioSinkKind.usbDevice, name: 'early-dac'),
      _sink(id: 8, kind: AudioSinkKind.usbHeadset, name: 'headset-b'),
      _sink(id: 6, kind: AudioSinkKind.usbHeadset, name: 'headset-a'),
    ]);
    expect(chosen?.name, 'headset-a');
    expect(chosen?.id, 6);
  });

  test('an idle USB sink does not replace the routed speaker', () {
    final system = systemSink([
      _sink(id: 2, kind: AudioSinkKind.usbDevice, name: 'FiiO'),
      _sink(id: 1, kind: AudioSinkKind.speaker, routed: true),
    ]);
    expect(system?.kind, AudioSinkKind.speaker);

    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker, routed: true, sampleRates: const [48000]),
        _sink(id: 7, kind: AudioSinkKind.usbDevice, name: 'FiiO'),
      ],
      outputSampleRate: 48000,
    );
    expect(snapshot.routeLine, '路由：扬声器');
    expect(snapshot.via, '系统路径');
    expect(snapshot.usbConnected, isTrue);
    expect(snapshot.usbRouted, isFalse);
    expect(snapshot.currentOutputLine, contains('系统路径'));
    expect(snapshot.currentOutputLine, isNot(contains('直接输出')));
  });

  test('a routed USB sink is labeled as the system mix', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker),
        _sink(
          id: 7,
          kind: AudioSinkKind.usbDevice,
          name: 'FiiO',
          sampleRates: const [44100, 48000],
          routed: true,
        ),
      ],
      outputSampleRate: 48000,
    );
    expect(snapshot.currentOutputLine, '当前输出：48kHz / 16-bit（USB · 系统混音）');
    expect(snapshot.routeLine, '路由：USB · FiiO');
    expect(snapshot.brief, 'USB 48kHz');
    expect(snapshot.usbRouted, isTrue);
    expect(snapshot.currentOutputLine, isNot(contains('比特完美')));
    expect(snapshot.currentOutputLine, isNot(contains('独占')));
    expect(snapshot.route, isNot('U'));
  });

  test('missing PCM 16 stays unreported even if other encodings exist', () {
    expect(systemPathBitDepth(const []), isNull);
    expect(systemPathBitDepth(const [21, 22]), isNull);
    expect(systemPathBitDepth(const [androidEncodingPcm16, 21]), 16);
    final snapshot = describeRoute(
      sinks: [
        _sink(
          id: 7,
          kind: AudioSinkKind.usbDevice,
          name: 'FiiO',
          encodings: const [21],
          sampleRates: const [96000],
          routed: true,
        ),
      ],
      outputSampleRate: null,
    );
    expect(snapshot.bitDepth, isNull);
    expect(snapshot.sampleRate, 96000);
    expect(snapshot.brief, 'USB 96kHz');
    expect(snapshot.currentOutputLine, contains('位深未报告'));
  });

  test('speaker, wired, and USB labels are not a bluetooth route', () {
    expect(isBluetoothRoute('扬声器'), isFalse);
    expect(isBluetoothRoute('有线耳机'), isFalse);
    expect(isBluetoothRoute('USB · DAC'), isFalse);
    expect(isBluetoothRoute('U'), isFalse);
    expect(isBluetoothRoute('蓝牙'), isTrue);
  });

  test('a connected bluetooth sink shows even when another route is active', () {
    expect(kindFromAndroidType(androidTypeBluetoothA2dp), AudioSinkKind.bluetooth);
    expect(kindFromAndroidType(androidTypeBluetoothSco), AudioSinkKind.bluetooth);
    expect(kindFromAndroidType(androidTypeHearingAid), AudioSinkKind.bluetooth);
    expect(kindFromAndroidType(androidTypeBleHeadset), AudioSinkKind.bluetooth);
    expect(kindFromAndroidType(androidTypeBleSpeaker), AudioSinkKind.bluetooth);
    expect(kindFromAndroidType(androidTypeBleBroadcast), AudioSinkKind.bluetooth);

    final paired = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker, routed: true),
        _sink(id: 8, kind: AudioSinkKind.bluetooth, name: 'WH-1000XM5'),
      ],
      outputSampleRate: 44100,
    );
    expect(paired.route, '扬声器');
    expect(paired.bluetoothConnected, isTrue);
    expect(paired.usbRouted, isFalse);

    final playingBt = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker),
        _sink(id: 8, kind: AudioSinkKind.bluetooth, routed: true),
      ],
      outputSampleRate: 44100,
    );
    expect(playingBt.route, '蓝牙');
    expect(playingBt.bluetoothConnected, isTrue);

    for (final sinks in [
      [_sink(id: 1, kind: AudioSinkKind.speaker, routed: true)],
      [_sink(id: 3, kind: AudioSinkKind.wired, routed: true)],
      [
        _sink(
          id: 7,
          kind: AudioSinkKind.usbDevice,
          name: 'FiiO',
          routed: true,
        ),
      ],
    ]) {
      final snapshot = describeRoute(sinks: sinks, outputSampleRate: 48000);
      expect(snapshot.bluetoothConnected, isFalse);
      expect(snapshot.route, isNot('U'));
    }
  });
}

AudioSink _sink({
  required int id,
  AudioSinkKind kind = AudioSinkKind.speaker,
  String name = '',
  List<int> sampleRates = const [],
  List<int> encodings = const [androidEncodingPcm16],
  bool routed = false,
}) {
  return AudioSink(
    id: id,
    name: name,
    kind: kind,
    sampleRates: sampleRates,
    encodings: encodings,
    routed: routed,
  );
}
