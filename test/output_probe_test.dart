import 'package:flutter_test/flutter_test.dart';
import 'package:likepod/services/output_probe.dart';

void main() {
  test(
    'formats a known system rate and bit depth without a bit-perfect claim',
    () {
      final line = formatCurrentOutput(sampleRate: 44100, bitDepth: 16);
      expect(line, '当前输出：44.1kHz / 16-bit（系统路径）');
      expect(line.toLowerCase(), isNot(contains('bit-perfect')));
      expect(line, isNot(contains('比特完美')));
    },
  );

  test('does not invent a rate or depth when the probe is empty', () {
    const snapshot = OutputSnapshot.unknown;
    expect(snapshot.currentOutputLine, '当前输出：采样率未报告 / 位深未报告（系统路径）');
    expect(snapshot.brief, '未报告');
    expect(snapshot.trackLine, '曲目：未读取');
    expect(snapshot.routeLine, '路由：未报告');
    expect(
      nativeRateNote(
        trackSampleRate: null,
        deviceRates: const [],
      ),
      isNull,
    );
  });

  test('a rate with no USB preference stays unreported', () {
    expect(
      nativeRateNote(
        trackSampleRate: 44100,
        deviceRates: const [44100],
      ),
      isNull,
    );
  });

  test('USB accessory is not a DAC and a headset outranks a USB device', () {
    expect(
      kindFromAndroidType(androidTypeUsbHeadset),
      AudioSinkKind.usbHeadset,
    );
    expect(kindFromAndroidType(androidTypeUsbDevice), AudioSinkKind.usbDevice);
    expect(kindFromAndroidType(androidTypeUsbAccessory), AudioSinkKind.other);
    expect(
      kindFromAndroidType(androidTypeBuiltinSpeaker),
      AudioSinkKind.speaker,
    );

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

    final fallback = systemSink([
      _sink(id: 2, kind: AudioSinkKind.usbDevice, name: 'FiiO'),
      _sink(id: 1, kind: AudioSinkKind.speaker),
    ]);
    expect(fallback?.kind, AudioSinkKind.speaker);
  });

  test('a preferred USB sink is labeled as the system mix', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker),
        _sink(
          id: 7,
          kind: AudioSinkKind.usbDevice,
          name: 'FiiO',
          sampleRates: const [44100, 48000],
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: false,
      trackSampleRate: 44100,
      trackBitDepth: 16,
    );
    expect(snapshot.currentOutputLine, '当前输出：48kHz / 16-bit（USB · 系统混音）');
    expect(snapshot.routeLine, '路由：USB · FiiO');
    expect(snapshot.brief, 'USB 48kHz');
    expect(snapshot.usbStatusLine, isNull);
    expect(snapshot.usbPreferred, isTrue);
    _expectHonest(snapshot.currentOutputLine);
    expect(
      nativeRateNote(
        trackSampleRate: snapshot.trackSampleRate,
        deviceRates: snapshot.deviceSampleRates,
        usbPreferred: snapshot.usbPreferred,
        mixerAccepted: snapshot.mixerAccepted,
      ),
      '已请求 USB 输出，曲目 44.1kHz 仍走系统混音',
    );
  });

  test('an accepted sample-rate request stays unverified', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(
          id: 7,
          kind: AudioSinkKind.usbDevice,
          name: 'FiiO',
          sampleRates: const [44100, 48000, 96000],
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: true,
      trackSampleRate: 96000,
      trackBitDepth: 24,
    );
    expect(snapshot.currentOutputLine, '当前输出：96kHz / 16-bit（USB · 已请求采样率）');
    expect(snapshot.brief, 'USB 96kHz');
    final note = nativeRateNote(
      trackSampleRate: 96000,
      deviceRates: snapshot.deviceSampleRates,
      usbPreferred: true,
      mixerAccepted: true,
    );
    expect(note, '已向 USB 请求曲目 96kHz，未验证独占输出');
    _expectHonest(note);
    _expectHonest(snapshot.currentOutputLine);
  });

  test('a USB rate that is not listed stays unlisted', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(
          id: 7,
          kind: AudioSinkKind.usbHeadset,
          name: 'Headset',
          sampleRates: const [44100, 48000],
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: true,
      trackSampleRate: 192000,
    );
    expect(
      nativeRateNote(
        trackSampleRate: snapshot.trackSampleRate,
        deviceRates: snapshot.deviceSampleRates,
        usbPreferred: snapshot.usbPreferred,
        mixerAccepted: snapshot.mixerAccepted,
      ),
      '曲目 192kHz 不在 USB 采样率列表',
    );
  });

  test('USB that is present but not selected stays on the current route', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker, routed: true),
        _sink(id: 7, kind: AudioSinkKind.usbDevice, name: 'FiiO'),
      ],
      outputSampleRate: 48000,
      preferredApplied: false,
      mixerAccepted: false,
    );
    expect(snapshot.routeLine, '路由：扬声器');
    expect(snapshot.currentOutputLine, contains('系统路径'));
    expect(snapshot.usbPreferred, isFalse);
    expect(snapshot.usbConnected, isTrue);
    expect(snapshot.usbStatusLine, 'USB 已连接：FiiO，仍走当前路由');
    expect(snapshot.brief, '48kHz/16-bit');
    _expectHonest(snapshot.usbStatusLine);
  });

  test('a USB sink Android already routed is shown without a preference', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker),
        _sink(id: 7, kind: AudioSinkKind.usbDevice, name: 'FiiO', routed: true),
      ],
      outputSampleRate: 48000,
      preferredApplied: false,
      mixerAccepted: false,
    );
    expect(snapshot.routeLine, '路由：USB · FiiO');
    expect(snapshot.via, 'USB · 系统混音');
    expect(snapshot.usbStatusLine, isNull);
    expect(snapshot.mixerAccepted, isFalse);
  });

  test('unplug falls back to the speaker', () {
    final snapshot = describeRoute(
      sinks: [_sink(id: 1, kind: AudioSinkKind.speaker, name: 'phone')],
      outputSampleRate: 48000,
      preferredApplied: false,
      mixerAccepted: false,
      trackSampleRate: 44100,
    );
    expect(snapshot.usbConnected, isFalse);
    expect(snapshot.usbPreferred, isFalse);
    expect(snapshot.routeLine, '路由：扬声器');
    expect(snapshot.via, '系统路径');
    expect(snapshot.usbStatusLine, isNull);
    expect(snapshot.brief, '48kHz/16-bit');
  });

  test('a TYPE_USB_DEVICE DAC such as lifeme is selected by name', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker, routed: true),
        _sink(
          id: 11,
          kind: kindFromAndroidType(androidTypeUsbDevice),
          name: 'lifeme Hi-Fi Audio 3Pro',
          sampleRates: const [44100, 48000],
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: false,
      preferenceDetail: '已设置 · 播放器1 · 音轨1/0 实际=USB',
    );
    expect(snapshot.routeLine, '路由：USB · lifeme Hi-Fi Audio 3Pro');
    expect(snapshot.via, 'USB · 系统混音');
    expect(snapshot.preferenceLine, '偏好设备：已设置 · 播放器1 · 音轨1/0 实际=USB');
    expect(
      snapshot.preferenceLine!.toLowerCase(),
      isNot(contains('bit-perfect')),
    );
    expect(snapshot.usbStatusLine, isNull);
  });

  test('a failed USB preference keeps the speaker and explains why', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker, routed: true),
        _sink(
          id: 11,
          kind: AudioSinkKind.usbDevice,
          name: 'lifeme Hi-Fi Audio 3Pro',
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: false,
      mixerAccepted: false,
      preferenceDetail: '失败 · 没有播放器 · 音轨0 · 媒体=扬声器',
    );
    expect(snapshot.routeLine, '路由：扬声器');
    expect(snapshot.usbStatusLine, contains('lifeme Hi-Fi Audio 3Pro'));
    expect(snapshot.preferenceLine, '偏好设备：失败 · 没有播放器 · 音轨0 · 媒体=扬声器');
  });

  test('a direct USB stream follows 44.1 and does not claim bit-perfect', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker, routed: true),
        _sink(
          id: 11,
          kind: AudioSinkKind.usbDevice,
          name: 'lifeme Hi-Fi Audio 3Pro',
          sampleRates: const [44100, 48000],
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: false,
      trackSampleRate: 44100,
      trackBitDepth: 16,
      directActive: true,
      directRate: 44100,
      directBitDepth: 16,
      directDetail: '已打开 · 44.1kHz · 16-bit · UAC1',
      directName: 'lifeme Hi-Fi Audio 3Pro',
      directUi: 0.04,
      directGain: 1 / 32768,
    );
    expect(snapshot.routeLine, '路由：USB · lifeme Hi-Fi Audio 3Pro');
    expect(snapshot.via, 'USB · 直接输出');
    expect(snapshot.currentOutputLine, '当前输出：44.1kHz / 16-bit（USB · 直接输出）');
    expect(snapshot.directLine, '直接输出：已打开 · 44.1kHz · 16-bit · UAC1');
    expect(snapshot.softwareGainLine, '软件音量：4% → −90 dB');
    expect(snapshot.preferenceLine, isNull);
    expect(snapshot.currentOutputLine, isNot(contains('系统混音')));
    final note = nativeRateNote(
      trackSampleRate: 44100,
      deviceRates: snapshot.deviceSampleRates,
      directActive: true,
      directRate: 44100,
    );
    expect(note, contains('未走系统混音'));
    expect(note, contains('三次曲线软件音量'));
    expect(note, contains('−12 dB'));
    expect(note, isNot(contains('比特完美')));
    expect(note!.toLowerCase(), isNot(contains('bit-perfect')));
  });

  test('direct USB failure names the reason instead of staying silent', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker, routed: true),
        _sink(
          id: 11,
          kind: AudioSinkKind.usbDevice,
          name: 'lifeme Hi-Fi Audio 3Pro',
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: false,
      directDetail: '失败 · 没有 PCM 播放端点',
      directName: 'lifeme Hi-Fi Audio 3Pro',
    );
    expect(snapshot.via, 'USB · 系统混音');
    expect(snapshot.directLine, '直接输出：失败 · 没有 PCM 播放端点');
    expect(snapshot.directLine, isNot(contains('比特完美')));
    expect(snapshot.softwareGainLine, isNull);
  });

  test('direct USB gain stays unreported until the stream says so', () {
    final open = describeRoute(
      sinks: [_sink(id: 11, kind: AudioSinkKind.usbDevice, name: 'lifeme')],
      outputSampleRate: 44100,
      preferredApplied: true,
      mixerAccepted: false,
      directActive: true,
      directRate: 44100,
      directBitDepth: 16,
      directDetail: '已打开',
      directName: 'lifeme',
    );
    expect(open.softwareGainLine, '软件音量：未报告');
    expect(
      formatSoftwareGain(directActive: true, ui: 1, linear: 8230 / 32768),
      '软件音量：100% → −12 dB',
    );
    expect(
      formatSoftwareGain(directActive: true, ui: 0.04, linear: 1 / 32768),
      '软件音量：4% → −90 dB',
    );
    expect(
      formatSoftwareGain(directActive: true, ui: 0, linear: 0),
      '软件音量：0% → 静音',
    );
    expect(formatSoftwareGain(directActive: false, ui: 1, linear: 1), isNull);
  });

  test('a resampled direct stream says so', () {
    final note = nativeRateNote(
      trackSampleRate: 44100,
      deviceRates: const [48000],
      directActive: true,
      directResampled: true,
      directRate: 48000,
    );
    expect(note, contains('已重采样到 48kHz'));
    expect(note, isNot(contains('比特完美')));
  });

  test('a no-resample mixer is labeled without a bit-perfect claim', () {
    final snapshot = describeRoute(
      sinks: [
        _sink(id: 1, kind: AudioSinkKind.speaker),
        _sink(
          id: 11,
          kind: AudioSinkKind.usbDevice,
          name: 'lifeme Hi-Fi Audio 3Pro',
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: true,
      mixerBitPerfect: true,
      trackSampleRate: 44100,
      trackBitDepth: 16,
    );
    expect(snapshot.via, 'USB · 无重采样');
    expect(snapshot.currentOutputLine, contains('44.1kHz'));
    expect(snapshot.currentOutputLine, isNot(contains('比特完美')));
    expect(
      nativeRateNote(
        trackSampleRate: 44100,
        deviceRates: const [],
        usbPreferred: true,
        mixerBitPerfect: true,
      ),
      '系统已接受无混音请求，未在 DAC 端核对',
    );
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
        ),
      ],
      outputSampleRate: null,
      preferredApplied: true,
      mixerAccepted: false,
    );
    expect(snapshot.bitDepth, isNull);
    expect(snapshot.sampleRate, 96000);
    expect(snapshot.brief, 'USB 96kHz');
    expect(snapshot.currentOutputLine, contains('位深未报告'));
  });

  test('only the bluetooth route draws a status mark', () {
    expect(isBluetoothRoute('扬声器'), isFalse);
    expect(isBluetoothRoute('有线耳机'), isFalse);
    expect(isBluetoothRoute('USB · DAC'), isFalse);
    expect(isBluetoothRoute('蓝牙'), isTrue);
  });

  test('background handoff is named on About', () {
    expect(formatBackgroundPath(''), isNull);
    expect(formatBackgroundPath('direct'), '后台播放：USB 直接输出');
    expect(formatBackgroundPath('mixer'), '后台播放：系统混音');
    final snapshot = describeRoute(
      sinks: [
        _sink(
          id: 7,
          kind: AudioSinkKind.usbDevice,
          name: 'DAC',
          sampleRates: const [48000],
        ),
      ],
      outputSampleRate: 48000,
      preferredApplied: true,
      mixerAccepted: false,
      backgroundMixer: true,
      backgroundPath: 'mixer',
    );
    expect(snapshot.via, 'USB · 后台混音');
    expect(snapshot.backgroundLine, '后台播放：系统混音');
    expect(snapshot.currentOutputLine, contains('USB · 后台混音'));
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

void _expectHonest(String? line) {
  expect(line, isNotNull);
  expect(line!.toLowerCase(), isNot(contains('bit-perfect')));
  expect(line, isNot(contains('比特完美')));
  expect(line.toLowerCase(), isNot(contains('dsd')));
}
