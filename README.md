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

## 设置与评分持久化

机身外观、屏幕风格、滚轮音效、触感反馈、随机/重复、音量、歌曲星级，以及上次播放的曲目、队列和进度会写入 `shared_preferences`。下次启动会回到主菜单，并在暂停状态下恢复上次曲目与进度，按播放即可续听。

Shell theme, screen theme, click-wheel sound, haptics, shuffle, repeat, volume, star ratings, and the last track / queue / position are stored with `shared_preferences`. The next launch stays on the main menu and restores that track paused.

## Android 后台播放

播放走系统混音（just_audio）。插入 USB DAC 时由 Android 自己的 USB 音频路由出声，应用不申请 usbfs、不独占接口。其他应用拿走音频焦点时 LikePod 暂停；若这次暂停只是因为焦点被抢走，对方放开音频后会自动续播。用户自己按暂停，或下次冷启动，都不会自动播。

播放开始后，`audio_service` 会启动 `mediaPlayback` 前台服务，通知栏和锁屏提供上一首、播放/暂停、下一首，并跟随现有的随机与重复逻辑。暂停时服务仍保持前台（`androidStopForegroundOnPause: false`），避免 Android 12+ 在后台无法重新开始前台服务。

`audio_service` starts a `mediaPlayback` foreground service when playback begins. The notification and lock screen expose previous, play/pause, and next, using the same shuffle and repeat rules. The service stays in the foreground while paused so Android 12+ can resume it.

仍未覆盖 / still open:

- 通知栏封面只用 MediaStore 专辑图 URI（`content://media/external/audio/albumart/{id}`）。内嵌 ID3 封面不会写进通知，屏幕里的封面预览不受影响。
- 进程被系统或厂商省电策略杀掉后，不会从通知栏冷启动自动续播。再次打开应用会恢复上次进度（暂停），需要再按播放。
- 从最近任务划掉应用时，系统可能拆掉媒体服务。
- 没有 Android Auto，也没有自定义通知布局。
- 滚轮点击音仍走 `audioplayers`，不进入媒体会话。

Windows 平台目录未包含在初始导入中。需要时可用下面的命令重新生成：

The Windows platform folder was omitted from the initial import. Regenerate it when needed:

```bash
flutter create . --platforms=windows
```
