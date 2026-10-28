# 参与 / Contributing

用 Flutter 构建。改动请附上能说明行为的测试；已有测试的部件，改了就要让原来的测试继续通过。

Build with Flutter. Include a test when the change has a behavior worth locking in. If a widget already has tests, keep those passing.

## 环境 / Setup

- Flutter SDK（与本仓库当前引擎一致即可；已发布的 v0.1.0 包是 minSdk 24、targetSdk 36）
- Android SDK，用来打 APK

- Flutter SDK (a current stable SDK that can build this tree; the shipped v0.1.0 package is minSdk 24, targetSdk 36)
- Android SDK, for the APK

```bash
flutter pub get
flutter analyze
flutter test
```

arm64 发布包：

arm64 release package:

```bash
flutter build apk --release --target-platform android-arm64
```

本地打出来的包用你自己机器上的签名。它和 `BASELINE.md` 里的 v0.1.0 证书不一定相同，不能当成那一个已发布的包。

A package you build locally is signed on your machine. It is not necessarily the v0.1.0 certificate in `BASELINE.md`, and it is not a substitute for that published file.

## 许可 / License

贡献以仓库根目录的 MIT `LICENSE` 发布。新增第三方代码、字体或图标时，更新 `THIRD_PARTY_NOTICES`，需要全文的许可放进 `licenses/`，并让应用内「关于 → 开源许可」的短名单与之相符。Noto Sans SC 的 OFL-1.1 在 `licenses/NotoSansSC-OFL.txt`。

Contributions are released under the MIT `LICENSE` at the repo root. When you add third-party code, fonts, or icons, update `THIRD_PARTY_NOTICES`, put full license texts in `licenses/` when they are required, and keep the in-app About → 开源许可 list in step. The Noto Sans SC OFL-1.1 text is `licenses/NotoSansSC-OFL.txt`.
