# My Cover Studio V1

原生 iPhone/iPad 本地翻唱工作室。SwiftUI + AVFoundation，最低 iOS/iPadOS 17，使用 Xcode 26 构建；没有服务器、用户账号或第三方运行依赖。

核心代码支持本地伴奏导入与半音变调、练习与正式音视频录制、多个 Take、非破坏混音/歌词标记、照片/补拍、带/无字幕导出，以及完整/精简/自定义工程包和安全恢复。AI 分离、自动歌词对齐/逐字、自动修音、智能拼接及 4K 尚未开放。

**构建成功不代表 AirPods、相机、同步、Files 云备份或真实设备迁移已经通过。** 当前逐项证据与缺口见 [交付状态](docs/DELIVERY_STATUS.md)。没有签名材料或已验证可安装 IPA。

`b3bfcdf` 已通过 23 项核心测试、双架构无签名编译及两秒真实离线导出/字幕/工程包恢复检查。实际报告和输出帧见 [验证记录](docs/validation/2026-10-24/README.md)。

`f569647` 补齐编辑页导出前的画面/字幕预览，通过独立的裁剪、镜像、字幕帧及缓存/数据保护检查；见 [预览验证](docs/validation/2026-10-24-preview/README.md)。

`9480730` 增加持久历史成品目录、未登记文件管理、自定义成品选择与源释放保护，通过 28 项核心测试和双架构编译；见 [成品/备份验证](docs/validation/2026-10-24-catalog/README.md)。

`f3b6b23` 增加无需重新开麦的录制收尾、原件登记/管理，以及复制的真实空间预算和失败暂存保护，通过 33 项核心测试和双架构编译；见 [恢复验证](docs/validation/2026-10-24-recovery/README.md)。保留尾段字节不等于恢复了可播放或同步录音。

`ab45992` 补齐独立字幕描边与旧工程兼容，通过 34 项核心测试、双架构编译和中英文描边/填充帧检查；见[描边证据与失败修复](docs/validation/2026-10-24-outline/README.md)。

`ffa7639` 保护未结束录制日志，防止新 Take 覆盖，并检查异步启动取消；38 项核心测试和双架构编译通过，实际取消/采集交互仍待设备验证，见[日志与启动验证](docs/validation/2026-10-24-capture-start/README.md)。

`37e6ba4` 隔离单工程坏索引，提供校验上一版后创建独立恢复副本、逐文件另存及外部包恢复；44 项核心测试和双架构编译通过。原坏目录保留，未知尾段不伪造 Take；见[坏索引恢复验证](docs/validation/2026-10-24-library-recovery/README.md)。

`1a05390` 增加启动失败页/重试、显式保留根事务日志和坏安全索引下的逐原件另存；50 项核心测试和双架构编译通过。页面/Files 交互尚待验证，见[启动保护证据](docs/validation/2026-10-24-startup-recovery/README.md)。

`136103c` 修复安全副本原件入口，在单个 iPhone Simulator 通过 1 条真实原生 UI 流程，50 项核心测试和双架构编译继续通过；六张截图、原件哈希核对与实际范围见[原生 UI 验证](docs/validation/2026-10-24-startup-ui/README.md)。这不代表录制、Files 或实机验收通过。

`14fe7fa` 在单个 iPad 横屏 Simulator 也通过恢复交互、原件/日志/副本核对，50 项核心测试和双架构编译通过。截图裁剪限制及已有录像的有限观察见 [iPad 证据](docs/validation/2026-10-24-ipad-ui/README.md)。录制控制锁与固定停止栏已实现并编译，实际录制仍须真机验证。

`94c89a9` 修复练习回听可能停止正式录制伴奏、跨页单击停止绕过长按的问题，50 项核心测试与双架构应用编译通过；[检查范围](docs/validation/2026-10-24-recording-controls/README.md)。真实录制手势和设备路由仍待验证。

## 构建

在 macOS 打开 `MyCoverStudio.xcodeproj`，选择共享 scheme `MyCoverStudio`。命令行：

```sh
swift test --parallel
xcodebuild -project MyCoverStudio.xcodeproj -scheme MyCoverStudio -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Windows 可修改源码，并用 Python 标准库检查可复现工程配置：

```powershell
python scripts/generate_project.py
python scripts/validate_configuration.py
```

GitHub Actions 仅在 PR opened/ready_for_review 或手动运行时集中验证；普通 push 不触发。详见 [构建与真实签名](docs/BUILD.md)。

## 使用与数据保护

右上角 + 导入已有伴奏；四个入口是练习、录制、编辑、作品库。原始素材独立保存；效果、镜像、字幕和导出不覆盖它们。危险空间保护性停止，不自动删除录制。默认关闭耳返，蓝牙能力必须实机验证。

通过系统 Files 把 `.coverproject` 包保存到 Google Drive/iCloud Drive。**Files 接收文件不等于云端上传完成。** 外部包需重新读取验证；精简备份排除的 Take 不能在释放本地素材后从该包恢复。释放与永久删除需要两次确认。

- [使用、备份与格式](docs/USER_GUIDE.md)
- [技术决策 ADR](docs/IMPLEMENTATION_ADR.md)
- [逐项交付及验证记录](docs/DELIVERY_STATUS.md)
- [冻结的用户决定](docs/DECISIONS.md)、[PRD](docs/PRD.md)、[验收门槛](docs/QUALITY_GATES.md)

原始需求交付文档保留，描述的是最初冻结设计。实际实现、降级和验证结果以交付状态为准；未验证功能不会报告为实机通过。
