# 更多格式：实际解码与新版 IPA

应用代码 `05e51ce7a1a8b974ff0210249a7f1c7aeca6888a`，[Actions 40094808859](https://github.com/lunnn325/Cover-Studio/actions/runs/40094808859)，job `120874723023`，整体成功。

55 项核心 XCTest 通过，含新增 5 项本地真实音频解码/文件系统测试。Release iphoneos arm64 应用编译、IPA 打包和上传通过；未重复模拟器 UI 或整套成品导出。Xcode 26.6 / Swift 6.3.3（Swift 5 语言模式），实际工具链和原始日志保留于本目录。

## 实际运行范围

- 两份 0.5 秒自生成 OGG/Vorbis：44.1 kHz 单声道、48 kHz 立体声。通过 C 解码器写出 PCM CAF，再经 AVAudioFile 读回非零有限采样，检查峰值、声道、采样率、时长和 440 Hz 音高（内部窗口排除 AAC/MP3 编码填充，误差门槛 8 Hz）。
- 原有 MP3/M4A/WAV 及新增 AAC、FLAC、AIFF、CAF 的自有短音频实际解码，未只检查扩展名。
- 截断、CRC 损坏、串接 Ogg、伪 Ogg、真实 Ogg/Opus 均拒绝，不发布部分音频成功，输入字节保持不变。
- 导入 OGG 后原始 source 和派生 backing 是两个独立资产；删除本次临时解码目录后，完整/精简/自定义三种工程包仍恢复原件哈希及可解码 CAF。
- 源文件在准备和导入间变化时拒绝提交；选择“需要去原唱”仅保存原曲，不伪造伴奏。

测试数据是独立生成的 440 Hz 波形，十个 fixture 的内容/生成方式与 SHA-256 可查看，不含用户歌曲。没有把 Ogg/Opus、环绕声、串接/多流、受保护文件或所有罕见编码宣称为支持。OGG 解码器限制见 ADR 018。

## 下载产物

- `dist/MyCoverStudio-1.0.1-unsigned.ipa`，也更新了原 `MyCoverStudio-V1-unsigned.ipa` 路径。
- 版本 1.0.1 / build 2，1,475,769 字节，bundle ID `studio.mycover.app`，最低 iOS/iPadOS 17、iPhone/iPad、arm64 iOS device。
- IPA SHA-256：`3cf60d2401fe35210b55f16bc8b57c120a1a75e2845c63c5351dc6e2454ec712`。
- 下载后独立复核 ZIP、元数据、Mach-O device 平台和 CI 摘要一致；MIT 许可文本确实打进 IPA，测试 fixtures 未打入应用。
- IPA artifact `12560865128`，外层 ZIP SHA-256 `23f6af0578b4991db7f90992b036cf18197a4776f61507b4d08882e1547b3e19`。
- 日志 artifact `12560765406`，外层 ZIP SHA-256 `3847c1a29f258d64040ae4deee5065d8add72824ea5304ccdcaaba7d78d649d8`。

包仍需用户本地签名。用户仅报告上一版 1.0 安装成功；本轮没有测真实 Files 提供者、用户实际 OGG、设备播放/录制、AirPods、声学同步或跨设备迁移。新增格式的运行证据来自 macOS 同一核心解码/归档代码与 iOS 设备编译，不扩大成全部实机 gate 通过。
