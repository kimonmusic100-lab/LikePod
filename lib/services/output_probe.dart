import 'dart:math' as math;

/// Read-only description of the output path.
///
/// Numbers come from Android when a probe succeeds. Missing values stay
/// unreported. Direct USB means this app writes isochronous packets itself.
/// That is not a verified bit-identical path.
class OutputSnapshot {
  final int? sampleRate;
  final int? bitDepth;
  final String route;
  final List<int> deviceSampleRates;
  final int? trackSampleRate;
  final int? trackBitDepth;

  /// Parenthetical on the output line, such as `系统路径` or `USB · 系统混音`.
  final String via;

  /// A USB headset or USB audio device is attached.
  final bool usbConnected;

  /// The line describes that USB sink (preferred, or already the system route).
  final bool usbPreferred;

  /// Android accepted a sample-rate request for the USB device.
  /// Exclusive output is still unverified.
  final bool mixerAccepted;

  final String usbName;

  /// Set when a USB device is attached but playback is still on another route.
  final String? usbFallbackLine;

  /// Why the USB preference was or was not applied. Empty when no USB sink.
  final String preferenceDetail;

  /// This app is writing the USB isochronous stream itself.
  final bool directActive;

  /// Wire rate of that stream. Zero when it is not open.
  final int directRate;

  /// USB subframe width. Zero when the stream is not open.
  final int directBitDepth;

  /// PCM was converted because the DAC alt setting had no exact track rate.
  final bool directResampled;

  /// 16-bit PCM was placed in a wider USB subframe.
  final bool directExpanded;

  /// Concrete direct-output result, including a failure reason.
  final String directDetail;

  /// Linear amplitude multiplied onto direct-path PCM. Negative when unknown.
  final double directGain;

  /// Click-wheel / media position before the direct-path curve. Negative when unknown.
  final double directUi;

  /// `direct` or `mixer` after playback continued with the screen off.
  /// Empty until the activity has been stopped during playback.
  final String backgroundPath;

  const OutputSnapshot({
    this.sampleRate,
    this.bitDepth,
    this.route = '',
    this.deviceSampleRates = const [],
    this.trackSampleRate,
    this.trackBitDepth,
    this.via = '系统路径',
    this.usbConnected = false,
    this.usbPreferred = false,
    this.mixerAccepted = false,
    this.usbName = '',
    this.usbFallbackLine,
    this.preferenceDetail = '',
    this.directActive = false,
    this.directRate = 0,
    this.directBitDepth = 0,
    this.directResampled = false,
    this.directExpanded = false,
    this.directDetail = '',
    this.directGain = -1,
    this.directUi = -1,
    this.backgroundPath = '',
  });

  static const unknown = OutputSnapshot();

  String get currentOutputLine =>
      formatCurrentOutput(sampleRate: sampleRate, bitDepth: bitDepth, via: via);

  String get routeLine => '路由：${route.isEmpty ? '未报告' : route}';

  String get trackLine =>
      formatTrack(sampleRate: trackSampleRate, bitDepth: trackBitDepth);

  String? get usbStatusLine {
    final line = usbFallbackLine;
    if (line == null || line.isEmpty) return null;
    return line;
  }

  /// Concrete result of asking Android to use the USB device.
  String? get preferenceLine {
    if (preferenceDetail.isEmpty) return null;
    return '偏好设备：$preferenceDetail';
  }

  /// Direct isochronous result. Null when no USB audio device was considered.
  String? get directLine {
    if (directDetail.isEmpty) return null;
    return '直接输出：$directDetail';
  }

  /// UI position and the PCM level it becomes on the direct path.
  String? get softwareGainLine => formatSoftwareGain(
    directActive: directActive,
    ui: directUi,
    linear: directGain,
  );

  /// Which path stayed audible after the activity left the screen.
  String? get backgroundLine => formatBackgroundPath(backgroundPath);

  /// Short label for the settings row.
  String get brief {
    if (usbPreferred) {
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
    int? trackSampleRate,
    int? trackBitDepth,
    bool clearTrack = false,
    String? via,
    bool? usbConnected,
    bool? usbPreferred,
    bool? mixerAccepted,
    String? usbName,
    String? usbFallbackLine,
    bool clearUsbFallback = false,
    String? preferenceDetail,
    bool? directActive,
    int? directRate,
    int? directBitDepth,
    bool? directResampled,
    bool? directExpanded,
    String? directDetail,
    double? directGain,
    double? directUi,
    String? backgroundPath,
  }) {
    return OutputSnapshot(
      sampleRate: sampleRate ?? this.sampleRate,
      bitDepth: bitDepth ?? this.bitDepth,
      route: route ?? this.route,
      deviceSampleRates: deviceSampleRates ?? this.deviceSampleRates,
      trackSampleRate: clearTrack
          ? trackSampleRate
          : (trackSampleRate ?? this.trackSampleRate),
      trackBitDepth: clearTrack
          ? trackBitDepth
          : (trackBitDepth ?? this.trackBitDepth),
      via: via ?? this.via,
      usbConnected: usbConnected ?? this.usbConnected,
      usbPreferred: usbPreferred ?? this.usbPreferred,
      mixerAccepted: mixerAccepted ?? this.mixerAccepted,
      usbName: usbName ?? this.usbName,
      usbFallbackLine: clearUsbFallback
          ? usbFallbackLine
          : (usbFallbackLine ?? this.usbFallbackLine),
      preferenceDetail: preferenceDetail ?? this.preferenceDetail,
      directActive: directActive ?? this.directActive,
      directRate: directRate ?? this.directRate,
      directBitDepth: directBitDepth ?? this.directBitDepth,
      directResampled: directResampled ?? this.directResampled,
      directExpanded: directExpanded ?? this.directExpanded,
      directDetail: directDetail ?? this.directDetail,
      directGain: directGain ?? this.directGain,
      directUi: directUi ?? this.directUi,
      backgroundPath: backgroundPath ?? this.backgroundPath,
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
/// USB accessory is not a DAC.
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

/// The route Android is already using, without promoting an idle USB sink.
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

/// 16 only when the device lists PCM 16. 24/32 are not the open path.
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

/// Picks the sink to show and the honest via-label.
///
/// [directActive] means this app is writing USB packets itself. [mixerBitPerfect]
/// means Android 14 read back a no-resample mixer at the track rate. Neither
/// string claims the samples were verified at the DAC.
OutputSnapshot describeRoute({
  required List<AudioSink> sinks,
  required int? outputSampleRate,
  required bool preferredApplied,
  required bool mixerAccepted,
  int? trackSampleRate,
  int? trackBitDepth,
  String preferenceDetail = '',
  bool directActive = false,
  int directRate = 0,
  int directBitDepth = 0,
  bool directResampled = false,
  String directDetail = '',
  String directName = '',
  bool mixerBitPerfect = false,
  double directGain = -1,
  double directUi = -1,
  bool backgroundMixer = false,
  String backgroundPath = '',
}) {
  final usb = chooseUsbSink(sinks);
  final system = systemSink(sinks);
  final hostName = directName.trim().isNotEmpty
      ? directName.trim()
      : (usb == null ? '' : usbDisplayName(usb));
  final expanded = directActive && directBitDepth > 16;

  if (directActive) {
    final label = hostName.isEmpty || hostName == 'USB'
        ? 'USB'
        : 'USB · $hostName';
    return OutputSnapshot(
      sampleRate: directRate > 0 ? directRate : null,
      bitDepth: directBitDepth > 0 ? directBitDepth : null,
      route: label,
      deviceSampleRates: directRate > 0 ? [directRate] : const [],
      trackSampleRate: trackSampleRate,
      trackBitDepth: trackBitDepth,
      via: 'USB · 直接输出',
      usbConnected: true,
      usbPreferred: true,
      mixerAccepted: false,
      usbName: hostName.isEmpty ? 'USB' : hostName,
      preferenceDetail: '',
      directActive: true,
      directRate: directRate,
      directBitDepth: directBitDepth,
      directResampled: directResampled,
      directExpanded: expanded,
      directDetail: directDetail,
      directGain: directGain,
      directUi: directUi,
      backgroundPath: backgroundPath,
    );
  }

  final AudioSink? shown;
  final bool showUsb;
  final String? fallback;
  if (usb != null && preferredApplied) {
    shown = usb;
    showUsb = true;
    fallback = null;
  } else if (system != null && isUsbKind(system.kind)) {
    shown = system;
    showUsb = true;
    fallback = null;
  } else if (usb != null && usb.routed) {
    shown = usb;
    showUsb = true;
    fallback = null;
  } else if (usb != null || hostName.isNotEmpty) {
    shown = system;
    showUsb = false;
    final name = hostName.isNotEmpty ? hostName : usbDisplayName(usb!);
    fallback = name == 'USB' ? 'USB 已连接，仍走当前路由' : 'USB 已连接：$name，仍走当前路由';
  } else {
    shown = system;
    showUsb = false;
    fallback = null;
  }

  final bitPerfect =
      showUsb && preferredApplied && mixerBitPerfect && !backgroundMixer;
  final accepted =
      showUsb &&
      preferredApplied &&
      mixerAccepted &&
      !bitPerfect &&
      !backgroundMixer;
  final via = !showUsb
      ? '系统路径'
      : backgroundMixer
      ? 'USB · 后台混音'
      : bitPerfect
      ? 'USB · 无重采样'
      : (accepted ? 'USB · 已请求采样率' : 'USB · 系统混音');

  int? rate;
  if ((bitPerfect || accepted) &&
      trackSampleRate != null &&
      trackSampleRate > 0) {
    rate = trackSampleRate;
  } else if (outputSampleRate != null && outputSampleRate > 0) {
    rate = outputSampleRate;
  } else if (shown != null && shown.sampleRates.length == 1) {
    rate = shown.sampleRates.first;
  }

  final route = shown == null
      ? ''
      : (showUsb ? usbRouteLabel(shown) : labelForKind(shown.kind));

  return OutputSnapshot(
    sampleRate: rate,
    bitDepth: systemPathBitDepth(shown?.encodings ?? const []),
    route: route,
    deviceSampleRates: shown?.sampleRates ?? const [],
    trackSampleRate: trackSampleRate,
    trackBitDepth: trackBitDepth,
    via: via,
    usbConnected: usb != null || hostName.isNotEmpty,
    usbPreferred: showUsb,
    mixerAccepted: accepted || bitPerfect,
    usbName: hostName.isNotEmpty
        ? hostName
        : (usb == null ? '' : usbDisplayName(usb)),
    usbFallbackLine: fallback,
    preferenceDetail: usb == null && hostName.isEmpty ? '' : preferenceDetail,
    directDetail: usb == null && hostName.isEmpty ? '' : directDetail,
    directResampled: directResampled,
    backgroundPath: backgroundPath,
  );
}

/// About line for the path that stayed up after Home.
/// Null until a background handoff has been recorded.
String? formatBackgroundPath(String path) {
  switch (path) {
    case 'direct':
      return '后台播放：USB 直接输出';
    case 'mixer':
      return '后台播放：系统混音';
    default:
      return null;
  }
}

/// UI position and the PCM level after the cubic curve.
/// Example: `软件音量：4% → −90 dB`. Null when the direct path is closed.
String? formatSoftwareGain({
  required bool directActive,
  required double ui,
  required double linear,
}) {
  if (!directActive) return null;
  if (ui < 0 || linear < 0 || ui.isNaN || linear.isNaN) {
    return '软件音量：未报告';
  }
  final pct = (ui.clamp(0.0, 1.0) * 100).round();
  if (linear <= 0) return '软件音量：$pct% → 静音';
  final db = 20 * math.log(linear.clamp(1e-12, 1.0)) / math.ln10;
  final rounded = db.round();
  if (rounded >= 0) return '软件音量：$pct% → 0 dB';
  return '软件音量：$pct% → −${rounded.abs()} dB';
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

String formatTrack({int? sampleRate, int? bitDepth}) {
  if ((sampleRate == null || sampleRate <= 0) &&
      (bitDepth == null || bitDepth <= 0)) {
    return '曲目：未读取';
  }
  final rate = sampleRate == null || sampleRate <= 0
      ? '采样率未报告'
      : formatHz(sampleRate);
  final bits = bitDepth == null || bitDepth <= 0 ? '位深未报告' : '$bitDepth-bit';
  return '曲目：$rate / $bits';
}

/// A USB preference says whether the track rate was requested. Playback
/// still goes through the system mixer unless noted as an unverified
/// direct request.
String? nativeRateNote({
  required int? trackSampleRate,
  required List<int> deviceRates,
  bool usbPreferred = false,
  bool mixerAccepted = false,
  bool directActive = false,
  bool directResampled = false,
  bool directExpanded = false,
  int directRate = 0,
  int directBitDepth = 0,
  bool mixerBitPerfect = false,
}) {
  if (directActive) {
    if (directResampled &&
        trackSampleRate != null &&
        trackSampleRate > 0 &&
        directRate > 0) {
      return '直接写入 USB，曲目 ${formatHz(trackSampleRate)} 已重采样到 ${formatHz(directRate)}。三次曲线软件音量，满幅上限 −12 dB，未核对比特一致';
    }
    final expanded = directExpanded && directBitDepth > 16
        ? '。曲目 16-bit 放入 $directBitDepth-bit 子帧'
        : '';
    return '直接写入 USB，未走系统混音。三次曲线软件音量，满幅上限 −12 dB，未核对比特一致$expanded';
  }
  if (trackSampleRate == null || trackSampleRate <= 0) {
    return null;
  }
  if (usbPreferred && mixerBitPerfect) {
    return '系统已接受无混音请求，未在 DAC 端核对';
  }
  if (usbPreferred) {
    final listed = deviceRates.isEmpty || deviceRates.contains(trackSampleRate);
    if (!listed) {
      return '曲目 ${formatHz(trackSampleRate)} 不在 USB 采样率列表';
    }
    if (mixerAccepted) {
      return '已向 USB 请求曲目 ${formatHz(trackSampleRate)}，未验证独占输出';
    }
    return '已请求 USB 输出，曲目 ${formatHz(trackSampleRate)} 仍走系统混音';
  }
  return null;
}
