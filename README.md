# My Cover Studio V1

原生 iPhone/iPad 本地翻唱工作室。SwiftUI + AVFoundation，最低 iOS/iPadOS 17，使用 Xcode 26 构建；没有服务器、用户账号或第三方运行依赖。

核心代码支持本地伴奏导入与半音变调、练习与正式音视频录制、多个 Take、非破坏混音/歌词标记、照片/补拍、带/无字幕导出，以及完整/精简/自定义工程包和安全恢复。AI 分离、自动歌词对齐/逐字、自动修音、智能拼接及 4K 尚未开放。

**构建成功不代表 AirPods、相机、同步、Files 云备份或真实设备迁移已经通过。** 当前逐项证据与缺口见 [交付状态](docs/DELIVERY_STATUS.md)。没有签名材料或已验证可安装 IPA。

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
