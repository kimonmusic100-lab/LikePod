# LikePod 首视频无声问题 — 历史记录

> **0.1.0+32 已删除 USB 独占。** 日常播放只走 Android 系统混音（just_audio）。下面的 usbfs / 让渡 / 复位记录只解释为什么独占被拿掉，不再描述当前代码。若以后要研究独占，应另开分支重新引入，而不是在此树里留开关。

# LikePod 首视频无声问题 — 完整交接文档

> 写给下一位接手的 AI 或工程师。所有结论都有日志与 dump 佐证,存档位置见文末。

## 现象

LikePod(iPod 风格播放器,Flutter + 原生 Kotlin/C)在后台播放时,用户打开小红书/抖音/B站等 feed 应用播放视频:**对方 app 无声**(显示在播、数据在写、无报错)。LikePod 自己的一切(直连、后台保活、自动恢复)均已正常。

## 架构背景

LikePod 独占 USB DAC:usbfs 断开内核驱动(USBDEVFS_DISCONNECT),自建等时传输直写 PCM。对方 app 需要音频时,LikePod"让渡":停流 → 释放接口 → USBDEVFS_CONNECT 归还内核驱动 → 对方走系统混音。

## 已被证伪的假设(按时间序,全部有日志证据)

1. ~~焦点让渡太慢~~ → 重排后 100ms 内完成,无效
2. ~~CAN_DUCK 未处理~~ → 已处理,无效
3. ~~焦点归还后未重新请求~~ → 强制重请求,无效
4. ~~内核驱动未归还~~ → GETDRIVER 查询确认 bound=2 orphan=0,驱动完整
5. ~~端口未复位~~ → USBDEVFS_RESET 每次让渡都执行且成功,无效
6. ~~复位时机晚于对方建流~~ → 预复位(直连建立时复位)仍无效
7. ~~设备状态未广播~~ → setDeviceConnectionState/AudioManager.toggle 均被权限挡死(SecurityException)

## 最终确认的因果链(当前最可信模型)

让渡时 usbfs 断开等时端点 → snd-usb-audio 的等时流状态机失效。**归还驱动后,AudioFlinger/USB HAL 层持有的旧 pcm 句柄对已失效端点的引用不会恢复**。对方 app 在让渡后建的 AudioTrack 挂在 HAL 的这个坏流上:数据写入被吞(AudioFlinger 显示 server 帧推进、Last write 正常,但 xhci 中断计数零增长 → 端到端零流量)。端口复位制造设备消失/重现,但:
- 重枚举后的 card ALSA 地址与设备 ID 不变(1924),app 侧看不到设备变化 → 不重建音轨
- 框架级强制广播(setDeviceConnectionState / setWiredDeviceConnectionState)需要系统权限,第三方应用被拒

**这是 MTK 平台 snd-usb-audio + USB HAL 句柄复用的平台级缺陷,应用层无法彻底修复。** 对照:USB Audio Player Pro 等独占播放器同样无法保证让渡后对方 app 立即出声。

## 部分有效的缓解(已实装在代码里)

- antibinge 熔断:60 秒窗口内"续播又被抢"判定为 feed 刷屏,站停自动续播 → 解决了"LikePod 与对方来回拉锯互掐",对方第二个视频起正常出声
- 每次让渡复位端口:对方**新开**的音轨(换视频)落在新鲜端点,有声
- 残留:**对方在让渡后 ~100ms 内建的第一个音轨**仍会哑(它建在复位完成前的旧端点上,且 app 不会重建)

## 明日可尝试的剩余方向

1. **改走系统混音**:不再独占 DAC。这是 0.1.0+32 采用的做法。
2. **让渡不归还驱动**:保持 usbfs 接口断开(不做 USBDEVFS_CONNECT、不复位),对方音频走扬声器而非 DAC;LikePod 恢复时秒回直连。产品语义变化:DAC 只服务 LikePod
3. **上报内核/平台**:所有证据(dumpsys media.audio_flinger 的 Threadloop write latency 异常、xhci 中断零增长、GETDRIVER bound=2、端口复位无效)齐备,可向 MTK 或 ALSA/snd-usb-audio 社区提交
4. **HAL 重挂载强制**:复位后反射调用 UsbAlsaManager 的重挂载逻辑(需系统权限,大概率被拒,未验证)

## 关键文件与数据存档

- 源码:`E:\AI\Zcode\LikePod\LikePod-source\`(最新状态,analyze 零告警 45/45 测试绿)
- 源码打包:`E:\AI\Zcode\LikePod\LikePod-source-latest.tar.gz`(516KB,排除构建产物)
- 最新 APK:`E:\AI\Zcode\LikePod\LikePod-0.1.0-latest-full-source-state.apk`(含全部缓解)
- 主日志:`E:\AI\Zcode\LikePod\usb-bug-trace.log`(第 1 天)、`day2-trace.log`、`day2-full.log`(第 2 天全量)
- AudioFlinger/dumpsys 现场:`E:\AI\Zcode\LikePod\dumps\`、`dumps2\`、`dumps3\`
- 构建环境:`source /e/AI/tools/env.sh` 后 `flutter build apk --release`(JDK17/Flutter 3.47.8/NDK 28.2 全在 E:\AI\tools)

## 诊断工具链(复用价值高)

- 旧的 just_audio 注入钩子带 LikePodSink 标签状态日志（该钩子已随独占实现删除）
- `AudioFlinger dump` 判据:音轨 server 帧推进 = app→AF 正常;HAL Timestamp cold 率 = AF→内核断点;Threadloop write latency(正常 <10ms,卡死时秒级~百秒级)= 内核端点卡死
- xhci 中断计数(`/proc/interrupts` 的 xhci-hcd:usb1)= 端到端流量的最终裁判
- USBDEVFS_GETDRIVER(nativeGetDriver)= 接口驱动归属查询

## 版本状态

versionName 0.1.0(versionCode 20,单调递增约束)。所有 APK 为 debug 签名,覆盖安装即可;从更早版本降级需先卸载。
