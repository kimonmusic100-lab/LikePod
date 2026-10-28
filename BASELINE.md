# LikePod v0.1.0 原始基准版 / release freeze

This is the official v0.1.0 freeze. The annotated tag `v0.1.0` points at the
nplayout commit below, not at later documentation commits.

这是正式的 v0.1.0 冻结。附注标签 `v0.1.0` 指向下面的 nplayout 提交，而不是之后只改文档的提交。

| | |
| --- | --- |
| versionName | `0.1.0` |
| versionCode | 50 |
| commit | `8b9084c92bb6785f91c19d60b5ac37a3b9313a33` |
| tag | `v0.1.0` (`e87b64d049f3300c441e28445eeb4cb3e3df1130`) |
| APK | `likepod-0.1.0-vc50-nplayout-mixer-arm64-release.apk` |
| size | 9552340 bytes |
| MD5 | `eca8a2c4c58c385593b2174b96cbb7d1` |
| Gofile | https://gofile.io/d/coBII1Bz |
| signing cert SHA-256 | `3b985a6d41f8ce1a6cd3ecc9f06b505f78493f8efb3e09983b6e46fcfadebb54` |

Key traits / 要点:

- Safe-zone launcher icon
- Capture policy set before playback, so the visualizer can read the track
- Wavetune mel bands, about 60 Hz–8 kHz, with a full-scale bin near 0.7
- 点阵柱 only
- Mixer only; USB exclusive playback has been removed
- Outer shell follows system rounded corners and does not clip the waveform
- About page is vertically centered and lists open-source notices
- No U2 theme
- No in-app Apple disclaimer. The README still says LikePod is not affiliated with Apple
- Now Playing cover, title, and artist sit with the cover’s left edge on the first waveform column
