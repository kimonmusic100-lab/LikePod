# LikePod

iPod Classic 风格的本地音乐播放器，使用 Flutter 构建。

LikePod is an iPod Classic-style local music player built with Flutter.

## 运行 / Run

本机或 CI 需要已安装 Flutter SDK。

The Flutter SDK must be installed locally or available in CI.

```bash
flutter pub get
flutter run
```

Windows 平台目录未包含在初始导入中。需要时可用下面的命令重新生成：

The Windows platform folder was omitted from the initial import. Regenerate it when needed:

```bash
flutter create . --platforms=windows
```
