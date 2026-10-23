# 官方技术参考（2026-10-24 检索核对）

以下是供 Codex 开发时继续核查的 Apple 文档和 WWDC 讲座。**仅证明 API/技术机制存在，不证明用户具体设备已成功运行。**

1. [AVAudioUnitTimePitch.pitch — Apple](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch/pitch) — 每半音 100 cents、pitch 与 rate 独立设置；实际音质另验。
2. [AVCaptureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording — Apple](https://developer.apple.com/documentation/avfoundation/avcapturesession/configuresapplicationaudiosessionforbluetoothhighqualityrecording) — 摄像头高质量蓝牙收音选项、使用条件。
3. [AVAudioSession.CategoryOptions.bluetoothHighQualityRecording — Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording) — 支持设备检查、HFP 回退、默认 mode 约束及地区可用性限制。
4. [Enhance your app’s audio recording capabilities — WWDC25](https://developer.apple.com/videos/play/wwdc2025/251/) — 输入设备选择、AirPods 高质量录音。
5. [AVAssetWriter.movieFragmentInterval — Apple](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval) — 分片媒体文件支持异常后部分可读取，容器有条件限制。
6. [AVAssetWriter.initialMovieFragmentInterval — Apple](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialmoviefragmentinterval) — 首片段可更早落盘以降低首次片段风险。
7. [AVFoundation export presets — Apple](https://developer.apple.com/documentation/avfoundation/export-presets) — 视频导出预设与格式支持应运行时检查。
8. [UIDocumentPicker — Apple 文档](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller) — 优先当前支持的系统文件接口，勿复制过时 deprecated API。

对 iOS 部分 API 的支持设备/系统版本、AVAssetWriter 容器/编解码、文件提供者上传完成状态、模型协议与许可，请在代码实施时以最新 SDK 文档及实机检测为准。
