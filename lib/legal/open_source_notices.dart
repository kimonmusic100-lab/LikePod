/// Short rows shown from About → 开源许可.
/// The full texts live in LICENSE, THIRD_PARTY_NOTICES, and licenses/.
class OpenSourceNotice {
  final String id;
  final String title;
  final String detail;

  const OpenSourceNotice(this.id, this.title, this.detail);
}

const List<OpenSourceNotice> openSourceNotices = [
  OpenSourceNotice('app', 'LikePod', 'MIT, Kimonmusic'),
  OpenSourceNotice('flutter', 'Flutter', 'BSD-3-Clause'),
  OpenSourceNotice('audio_service', 'audio_service 0.18.19', 'MIT, Ryan Heise'),
  OpenSourceNotice('audio_session', 'audio_session 0.2.4', 'MIT, Ryan Heise'),
  OpenSourceNotice('just_audio', 'just_audio 0.10.6', 'MIT, Ryan Heise'),
  OpenSourceNotice('exoplayer', 'Media3 ExoPlayer', 'Apache-2.0, 1.4.1'),
  OpenSourceNotice('audioplayers', 'audioplayers 6.8.1', 'MIT, Blue Fire'),
  OpenSourceNotice('permission', 'permission_handler', 'MIT, Baseflow'),
  OpenSourceNotice('provider', 'provider 6.1.5+1', 'MIT, Remi Rousselet'),
  OpenSourceNotice('prefs', 'shared_preferences', 'BSD-3, Flutter'),
  OpenSourceNotice('package_info', 'package_info_plus', 'BSD, Chromium'),
  OpenSourceNotice('path', 'path_provider 2.1.6', 'BSD-3, Flutter'),
  OpenSourceNotice('sqflite', 'sqflite 2.4.5', 'BSD-2, Tekartik'),
  OpenSourceNotice('jni', 'jni 1.1.0', 'BSD, Dart authors'),
  OpenSourceNotice('rxdart', 'rxdart 0.28.0', 'Apache-2.0'),
  OpenSourceNotice('roboto', 'Roboto', 'Apache-2.0'),
  OpenSourceNotice('material_icons', 'Material Icons', 'CC BY 4.0'),
  OpenSourceNotice('noto', 'Noto Sans SC', 'OFL-1.1, Adobe'),
  OpenSourceNotice('texts', '完整文本', '见仓库 licenses/'),
];
