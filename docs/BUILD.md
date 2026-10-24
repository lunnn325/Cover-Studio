# 构建与安装

这是原生 SwiftUI iPhone/iPad application，`MyCoverStudio.xcodeproj` 内有共享 scheme `MyCoverStudio`。领域模型和纯逻辑位于本地 Swift Package `CoverCore`；仅新增仓库内固定版本的 stb_vorbis C 解码器（MIT），无需联网拉取运行依赖。最低 iOS/iPadOS 17.0，Swift 5 语言模式；使用 Xcode 26 或更新 SDK 编译有条件的 iOS 26 能力，旧系统仍需运行时检测/降级。

## Windows 配置检查

需要 Python 3.10+，不需要安装 Ruby、XcodeGen 或联网下载构建工具。新增/移除 `App/**/*.swift` 后运行：

```powershell
python scripts/generate_project.py
python scripts/validate_configuration.py
```

生成器按文件路径产生稳定 ID，把所有 App Swift 文件编入原生 application target。生成的 pbxproj 和共享 scheme 一同提交；可用 `python scripts/generate_project.py --check` 检查是否过期。不要手工修改生成文件，修改生成脚本后重新生成。

配置检查验证引用完整、隐私/权限 plist、工程文档类型和源文件收录；**这不能证明 Swift 编译、布局或任何媒体功能已通过**。Windows 的 `python` 若指向 Microsoft Store 占位程序，改用已安装 Python 的完整路径。

## macOS 无签名集中构建

安装 Xcode 26+、iOS Simulator runtime，选择该 Xcode 的 Command Line Tools。在仓库根目录：

```sh
python3 scripts/validate_configuration.py
swift test --parallel
xcodebuild -project MyCoverStudio.xcodeproj -scheme MyCoverStudio -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

`swift test` 在 macOS 测试纯逻辑；CryptoKit 使用 Apple 系统实现。Simulator `.app` 位于 `build/DerivedData/Build/Products/Debug-iphonesimulator/MyCoverStudio.app`，不能安装至真实 iPhone/iPad。

## GitHub Actions

`.github/workflows/ios-milestone.yml` 使用官方 `macos-26` runner 标签，`select_xcode.py` 显式选择镜像已安装的最新稳定 Xcode 26，并记录实际 Xcode/Swift 与可用 Simulator runtime/设备清单。仅 Actions 手动 **Run workflow** 或 PR 的 `opened` / `ready_for_review` 里程碑触发（草稿首次打开也构建）；普通 push 与 PR synchronize 不触发。默认不打包 IPA；手动明确选择时可生成下述未签名设备 IPA，不使用签名 Secrets、不自动发布。

手动选择 `build_unsigned_ipa` 可沿用 William Lecture 的设备版流程：Release + `iphoneos` + arm64 + 禁用签名，将 `Payload/MyCoverStudio.app` 打包为 `dist/MyCoverStudio-V1-unsigned.ipa`。它不是模拟器 `.app` 改名；检查实际 Mach-O 的 iOS device 平台、版本/设备系列、ZIP 完整性并输出 SHA-256 和 `ipa-report.json`。仅选此项时跳过模拟器编译/启动，保留核心测试；artifact 保存 14 天。该包需在本地签名后安装，构建不读取证书、Apple ID 或仓库 Secrets，也不宣称已安装/通过实机验收。可在已选择 Xcode 的 Mac 上运行 `bash scripts/build-ios.sh` 重现打包。

PR `opened` 与 `ready_for_review` 两个明确里程碑默认截图及轻量合成媒体检查；手动运行可勾选 `simulator_snapshots`。同一次构建后各启动一个可用 iPhone/iPad Simulator（iPad 优先宽屏 Pro），保存浅色正常字号与深色辅助功能大字号截图。修复媒体路径可改选 `media_smoke_only`，只启动一个 iPhone，不重复已采集的布局证据；对应脚本参数 `--media-only`。可本地执行：

```sh
python3 scripts/simulator_snapshots.py --app build/DerivedData/Build/Products/Debug-iphonesimulator/MyCoverStudio.app
```

只检查编辑预览时，手动选择 `preview_check_only`（脚本 `--media-only --preview-only`，应用 DEBUG 参数 `--preview-smoke`）。这次只执行新 AVPlayerItem 预览管线，复用已有导出/工程包证据；报告的 `preview` 字段记录 1.5 秒方形裁剪、字幕帧、源哈希、队列不变和关闭后缓存状态。该模式不重新验证五种成品、工程迁移、交互播放器或真实听感。

描边增量在同一预览检查内复用已生成的干净画面，关闭阴影，比较中英文纯填充与 4 像素描边帧；`outlineDarkenedPixels` 分别记录变暗边缘数量，同时检查填充仍可见。只增加字幕帧提取，不重复生成混音/双版本输出；实际是否通过以对应报告为准。

手动 `startup_ui_check` 只运行一条原生 Simulator UI 流程，通过 `startup_ui_family` 单选 iPhone（默认）或 iPad；iPad 使用横屏并断言实际窗口宽大于高。不启动媒体检查或设备矩阵。`StartupUITests` 在设备跳过，应用 fixture 只编入 Debug Simulator，通过 `--startup-ui-fixture` 在独立 tmp 目录生成明确非媒体的测试字节；正常启动、Release 和设备不使用此路径。此模式实际点击启动保留确认、旧索引校验/创建副本、原件及日志页面，保存 XCTest 截图，并独立复核原件哈希、日志和副本数量。运行后仍需人工查看图片，不能推定 Files 提供者、摄像头、AirPods 或跨设备通过。

可在 macOS 运行 `python3 scripts/startup_ui_check.py --family iPad`（省略参数默认 iPhone）；它复用当前 DerivedData 做一个指定 UI test，结果在 `build/startup-ui-evidence/`，只有手动选中时执行。主工程生成器同时维护单个 UI test target，常规 build 不运行它；不需要安装外部测试框架。实际是否成功以对应 Actions/原始日志为准。

`simulator_snapshots` 的截图和 `scope.json` 是空状态启动/外观证据，需人工查看；手动启动/恢复 UI 的独立 `startup-ui-evidence/scope.json` 则只描述该条实际交互/文件检查。空状态证据不代表录制页、横屏、整条交互、真实相机、AirPods、声音、同步或备份恢复通过。截图失败会使已选择的步骤明确失败。CI 日志和截图保留 7 天。当前是否真正运行成功应以该次 Actions 记录和交付报告为准，不能由这些脚本存在推定。

同一步骤还会在手机 Simulator 使用 DEBUG 启动参数 `--media-smoke` 执行一次两秒合成自有素材检查，经真实离线混音、照片、字幕双 MP4、WAV 和工程包代码路径产生 `Documents/MediaSmokeReport.json`。正常启动不运行此检查。脚本最多等报告 120 秒，复制报告、两秒合成伴奏 WAV、小字幕帧与诊断，不上传用户内容或大视频。检查保留频谱与过零两个读数；220 Hz 升三半音应接近 261.63 Hz，时长仍为两秒。`passed` 不为 `true` 或超时都会明确失败；完整截图模式继续收集 iPad 空状态。这项轻量集成检查不能证明真实录制、AirPods、真人音质、设备同步或外部云端恢复通过。已通过的实际结果见 [保留证据](validation/2026-10-24/README.md)。

## 真机签名与安装

1. 在 macOS 用 Xcode 打开 `MyCoverStudio.xcodeproj`，选择 `MyCoverStudio` target。
2. 在 Signing & Capabilities 中选择本人真实 Apple 开发 Team；技术 bundle ID 默认 `studio.mycover.app`，如被占用，可在生成器内改为该 Team 可用的唯一 ID 并重新生成。工程文件类型 ID `studio.mycover.project` 应保持稳定。
3. 用可信任的真实 iPhone/iPad 选择 Run。免费个人 Team 的设备安装存在 Apple 限制；TestFlight/Ad Hoc/App Store 需相应有效开发资格、证书、描述文件及设备注册条件。
4. 分发时 Product → Archive，按该 Team 的合法渠道签名导出。将证书保存在 Keychain/受控 CI Secrets；不得提交 `.p12`、私钥、密码或 provisioning profile。

此仓库不含签名材料，目前没有可以宣称已成功安装的 IPA。发布前还需完成设备/权限配置复核及 `QUALITY_GATES.md` 真实设备冒烟。无签名构建不能替代这些结果。

应用包含不透明 1024×1024 靛蓝/白色音波图标，系统负责外部圆角。`scripts/generate_app_icon.py` 可用 Python + Pillow 重新生成；Pillow 仅开发时需要，正常检查、构建及应用运行不依赖它。

## 能力、隐私与设备边界

相机/麦克风权限只解释拍摄和录音本地用途。相册选择使用系统 PhotosPicker，备份使用系统 Files；没有账号、网络 entitlement、外部模型或后台持续录制声明。`PrivacyInfo.xcprivacy` 申报本机设置、磁盘容量保护、应用私有文件时间和单调时钟使用原因；有新 API 时需重新核对。

参考：[Apple 必须说明用途的 API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)、[GitHub runner-images 官方列表](https://github.com/actions/runner-images)。文档/API 存在只证明配置依据，不能解除真实设备技术风险。
