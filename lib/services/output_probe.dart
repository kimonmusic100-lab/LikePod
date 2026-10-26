/// Read-only description of the output Android is already using.
///
/// LikePod does not claim a USB interface and does not mark a route as
/// exclusive. A USB DAC shows up here only when the system mixer is
/// routed to it.
class OutputSnapshot {
  final int? sampleRate;
  final int? bitDepth;
  final String route;
  final List<int> deviceSampleRates;

  /// Parenthetical on the output line. USB stays on the system mixer.
  final String via;

  /// A USB headset or USB audio device is attached, routed or not.
  final bool usbConnected;

  /// The line describes the USB sink Android is currently routing to.
  final bool usbRouted;

  final String usbName;

  const OutputSnapshot({
    this.sampleRate,
    this.bitDepth,
    this.route = '',
    this.deviceSampleRates = const [],
    this.via = '系统路径',
    this.usbConnected = false,
    this.usbRouted = false,
    this.usbName = '',
  });

  static const unknown = OutputSnapshot();

  String get currentOutputLine =>
      formatCurrentOutput(sampleRate: sampleRate, bitDepth: bitDepth, via: via);

  String get routeLine => '路由：${route.isEmpty ? '未报告' : route}';

  /// Short label for diagnostics. Not drawn as a status letter.
  String get brief {
    if (usbRouted) {
      if (sampleRate == null || sampleRate! <= 0) return 'USB';
      return 'USB ${formatHz(sampleRate!)}';
    }
    if (sampleRate == null && bitDepth == null) return '未报告';
    if (sampleRate == null) return '$bitDepth-bit';
    if (bitDepth == null) return formatHz(sampleRate!);
    return '${formatHz(sampleRate!)}/$bitDepth-bit';
  }

  OutputSnapshot copyWith({
    int? sampleRate,
    int? bitDepth,
    String? route,
    List<int>? deviceSampleRates,
    String? via,
    bool? usbConnected,
    bool? usbRouted,
    String? usbName,
  }) {
    return OutputSnapshot(
      sampleRate: sampleRate ?? this.sampleRate,
      bitDepth: bitDepth ?? this.bitDepth,
      route: route ?? this.route,
      deviceSampleRates: deviceSampleRates ?? this.deviceSampleRates,
      via: via ?? this.via,
      usbConnected: usbConnected ?? this.usbConnected,
      usbRouted: usbRouted ?? this.usbRouted,
      usbName: usbName ?? this.usbName,
    );
  }
}

/// Android [AudioDeviceInfo] type values used for routing.
const int androidTypeBuiltinEarpiece = 1;
const int androidTypeBuiltinSpeaker = 2;
const int androidTypeWiredHeadset = 3;
const int androidTypeWiredHeadphones = 4;
const int androidTypeBluetoothSco = 7;
const int androidTypeBluetoothA2dp = 8;
const int androidTypeUsbDevice = 11;
const int androidTypeUsbAccessory = 12;
const int androidTypeUsbHeadset = 22;

/// [AudioFormat.ENCODING_PCM_16BIT]. just_audio submits this encoding.
const int androidEncodingPcm16 = 2;

enum AudioSinkKind { speaker, wired, bluetooth, usbHeadset, usbDevice, other }

class AudioSink {
  final int id;
  final String name;
  final AudioSinkKind kind;
  final List<int> sampleRates;
  final List<int> encodings;
  final bool routed;

  const AudioSink({
    required this.id,
    required this.name,
    required this.kind,
    this.sampleRates = const [],
    this.encodings = const [],
    this.routed = false,
  });
}

AudioSinkKind kindFromAndroidType(int type) {
  switch (type) {
    case androidTypeBuiltinEarpiece:
    case androidTypeBuiltinSpeaker:
      return AudioSinkKind.speaker;
    case androidTypeWiredHeadset:
    case androidTypeWiredHeadphones:
      return AudioSinkKind.wired;
    case androidTypeBluetoothSco:
    case androidTypeBluetoothA2dp:
      return AudioSinkKind.bluetooth;
    case androidTypeUsbHeadset:
      return AudioSinkKind.usbHeadset;
    case androidTypeUsbDevice:
      return AudioSinkKind.usbDevice;
    case androidTypeUsbAccessory:
      return AudioSinkKind.other;
    default:
      return AudioSinkKind.other;
  }
}

bool isUsbKind(AudioSinkKind kind) {
  return kind == AudioSinkKind.usbHeadset || kind == AudioSinkKind.usbDevice;
}

/// Headset first, then a USB audio device. Lowest id wins inside each group.
/// USB accessory is not a DAC. This does not select a playback device.
AudioSink? chooseUsbSink(List<AudioSink> sinks) {
  AudioSink? bestHeadset;
  AudioSink? bestDevice;
  for (final sink in sinks) {
    if (sink.kind == AudioSinkKind.usbHeadset) {
      if (bestHeadset == null || sink.id < bestHeadset.id) {
        bestHeadset = sink;
      }
    } else if (sink.kind == AudioSinkKind.usbDevice) {
      if (bestDevice == null || sink.id < bestDevice.id) {
        bestDevice = sink;
      }
    }
  }
  return bestHeadset ?? bestDevice;
}

/// The route Android is already using. An idle USB sink does not replace it.
AudioSink? systemSink(List<AudioSink> sinks) {
  if (sinks.isEmpty) return null;
  for (final sink in sinks) {
    if (sink.routed) return sink;
  }
  for (final kind in const [
    AudioSinkKind.speaker,
    AudioSinkKind.wired,
    AudioSinkKind.bluetooth,
  ]) {
    for (final sink in sinks) {
      if (sink.kind == kind) return sink;
    }
  }
  return sinks.first;
}

/// 16 only when the device lists PCM 16. Wider encodings are not the open path.
int? systemPathBitDepth(List<int> encodings) {
  if (encodings.contains(androidEncodingPcm16)) return 16;
  return null;
}

/// True when the current route label is Bluetooth. Speaker, wired, and USB
/// routes draw no extra status mark.
bool isBluetoothRoute(String route) {
  return route == '蓝牙';
}

String labelForKind(AudioSinkKind kind) {
  switch (kind) {
    case AudioSinkKind.speaker:
      return '扬声器';
    case AudioSinkKind.wired:
      return '有线耳机';
    case AudioSinkKind.bluetooth:
      return '蓝牙';
    case AudioSinkKind.usbHeadset:
    case AudioSinkKind.usbDevice:
      return 'USB';
    case AudioSinkKind.other:
      return '其他';
  }
}

String usbDisplayName(AudioSink sink) {
  final name = sink.name.trim();
  if (name.isEmpty || name == 'USB') return 'USB';
  return name;
}

String usbRouteLabel(AudioSink sink) {
  final name = usbDisplayName(sink);
  if (name == 'USB') return 'USB';
  return 'USB · $name';
}

/// Describes the sink Android is routing, without preferring or claiming USB.
OutputSnapshot describeRoute({
  required List<AudioSink> sinks,
  required int? outputSampleRate,
}) {
  final shown = systemSink(sinks);
  final usb = chooseUsbSink(sinks);
  final showUsb = shown != null && isUsbKind(shown.kind);
  final route = shown == null
      ? ''
      : (showUsb ? usbRouteLabel(shown) : labelForKind(shown.kind));

  int? rate;
  if (outputSampleRate != null && outputSampleRate > 0) {
    rate = outputSampleRate;
  } else if (shown != null && shown.sampleRates.length == 1) {
    rate = shown.sampleRates.first;
  }

  return OutputSnapshot(
    sampleRate: rate,
    bitDepth: systemPathBitDepth(shown?.encodings ?? const []),
    route: route,
    deviceSampleRates: shown?.sampleRates ?? const [],
    via: showUsb ? 'USB · 系统混音' : '系统路径',
    usbConnected: usb != null,
    usbRouted: showUsb,
    usbName: usb == null ? '' : usbDisplayName(usb),
  );
}

String formatHz(int hz) {
  if (hz <= 0) return '采样率未报告';
  if (hz % 1000 == 0) return '${hz ~/ 1000}kHz';
  final khz = hz / 1000.0;
  final text = khz.toStringAsFixed(1);
  return '${text}kHz';
}

/// Example: `当前输出：44.1kHz / 16-bit（系统路径）`.
String formatCurrentOutput({
  int? sampleRate,
  int? bitDepth,
  String via = '系统路径',
}) {
  final rate = sampleRate == null || sampleRate <= 0
      ? '采样率未报告'
      : formatHz(sampleRate);
  final bits = bitDepth == null || bitDepth <= 0 ? '位深未报告' : '$bitDepth-bit';
  return '当前输出：$rate / $bits（$via）';
}
