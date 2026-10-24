# iPad 初版反馈修复：1.0.2 / build 3

## 修复与数据边界

- 新完整 Take 起点问题：共享播放器保留练习/上一轮位置，同伴奏缓存又不 reload；preflight 从 playback.position 得到 capture.songStart 与实际播放起点。现改为 RecordingOrigin 明确区分完整新 Take=0、练习=合法当前位置、指定片段=指定秒数、恢复=保存末尾回退 3 秒。preflight 真正 seek，歌词滚动重置，capture/playback 沿用同一局部 songStart 与 host anchor，不是假显示 00:00。
- 歌词问题：录制页没有入口，编辑器的「完成」未把文本框写回模型。现有明确添加/编辑入口，TXT/LRC Files、本机粘贴/直接编辑进入草稿，保存直接解析文字并按 projectID/arrangementID 原子写入，成功才关闭；本层错误提示与失败保留草稿。练习/录制共用当前版本，旧 Take 后期使用其绑定版本。TXT 手动滚动，完整有效 LRC 按伴奏时间同步；异常标签保留文字，导入时提示修正，不伪造时间。
- iPad 宽横屏：左摄像头、右歌词/设置，窄窗口纵向；预览等比 fit，方向与采集设置一致。歌曲、Take、真实进度/时长置顶，主操作固定底部；音频诊断/耳返/延迟/空间位于高级设置，仍须确认实际收音/输出。录完自动保存后预览，可重录或进入后期；后期/作品库优先歌曲、Take、录制时长与预览，片段计数收在详情。
- 没有 schema 迁移、音视频覆盖/删除、清空工程或重建项目。此轮单 Agent，未使用 impeccable。原件保留断言使用隔离元数据/原始字节，不等于用户全部作品已做真实恢复验收。

## 构建与核心测试

[Actions 40098813576](https://github.com/lunnn325/Cover-Studio/actions/runs/40098813576)，应用代码 `2cdf6a2792588f2d16c79ce83997464fba6beb70`：60 核心 XCTest、arm64/x86_64 Simulator 编译、Release iphoneos arm64 编译、IPA 打包上传成功。该 run 后续 UI 失败，因此不能写成整个 run 成功。

新增五项测试覆盖：三次完整 Take 起点/仓库登记/原 Take 与源字节保留；练习/片段/恢复分流和边界；TXT/LRC、UTF-8/UTF-16 BOM、中文组合 emoji、错误扩展名/空/大/非文本/编码/缺文件；歌词写入与仓库重开、版本绑定、旧 Take 不变；负 offset 和未标记行编辑往返。它们不调用硬件采集。

初次 `37303a9` / run 40098408591 因测试浮点类型歧义未编译；修正后 `a5028d2` / run 40098683960 中 59/60 通过，Unicode 用例发现 Foundation 过滤误拒 emoji ZWJ。保留测试，修正为只拒绝真正控制码后 60/60 通过。失败原始片段与成功日志均保留，没有删断言。

## 安装包

- `dist/MyCoverStudio-1.0.2-unsigned.ipa`，1,553,516 字节，iPhone/iPad，最低 iOS/iPadOS 17，设备 arm64。
- 应用标识 `studio.mycover.app`；需沿用用户本地签名方式。没有读取 Apple 账号/证书/Secrets。
- SHA-256 `cbe672e407b5c624e8383bf6351b7423cc640319190e1bd5ca47831977bc8f06`。
- IPA artifact `12562002636`，ZIP SHA-256 `1e57dcaa00afa9c53bafee189332386da5856771b7d60d6d10aa885e2772571e`。
- Windows 独立复核 ZIP CRC、Info.plist、设备平台 LC_BUILD_VERSION=2、版本/标识/大小/哈希均与 CI 相同。报告见 ipa-report.json、local-ipa-verification.json。

## 原生界面检查范围

首次 iPad UI（同 run 40098813576）完成旧恢复界面并打开新的录制页面，但查找 SwiftUI HStack 容器的辅助功能元素失败，歌词用例尚未运行。录像末帧实际为左右分区、歌曲/Take/进度和固定底部主按钮；这不是全流程 PASS。原始失败 summary/scope/log 保留。

复验仅修改测试定位与脚本：检查真实控件位置，独立运行歌词单条 flow，避免重复完整恢复和 Release 打包。应用、核心和工程 source tree 与 IPA 完全一致，见 source-equivalence.json。[Actions 40100160436](https://github.com/lunnn325/Cover-Studio/actions/runs/40100160436)，测试提交 `54b338212880bc4921d097adea8400842dcde248`：60 核心测试、双架构编译和单条 iPad 原生歌词 UI 全部成功。iPad Pro 13-inch (M5) / iOS Simulator 26.4.1，测试实际执行 141.784 秒。实点添加 → 输入有效 LRC 后直接保存（未点「读取」）→ 录制页显示 → 练习页重新修改并保存 → 终止进程/同库重开 → 录制页显示新内容 → 再开编辑器核对。控件坐标确认左右分区，保存的 project.json 独立检查包含新歌词，原字节/保留日志/事务状态检查均通过，未创建恢复副本。此轮未重跑 Release。

四张完整原生截图已人工查看，显示添加入口、有效 LRC 首句高亮、跨页编辑重开后的普通文本及编辑器。测试第二次按光标插入无时间文本时拆开了第一时间标签；截图中的 `[` / `00:00.00]` 属于实际测试输入，原样保留且降为普通文本，不能用该图声称修改后的文本仍是有效 LRC。有效 LRC 证据为第 08 张；没有测试伴奏实际播放/自动滚动。

- [无歌词与添加按钮](07-record-empty-lyrics.png)
- [有效 LRC 保存后的横屏录制页](08-record-saved-lrc.png)
- [进程重启后读取新文本](09-record-lyrics-after-relaunch.png)
- [重新打开编辑器](10-reopened-lyrics-editor.png)

原始 ui-scope.json、ui-summary.json、ui-xcodebuild-test.log 与 fixture 哈希报告保留。成功 UI evidence artifact `12563056260`，ZIP SHA-256 `db58d0dda41bd7b7917a4e6ac440579c9d3c0888f0c904759dede7a0fde074af`。首次 UI evidence artifact `12562531659`，ZIP SHA-256 `e4593b33d08e78c88ead3d997319545acf46b3dee7bf249a0fbd6250d6a9d3af`。

## 仍需实机

尚未验证：真实 iPad 三次完整 Take 起点、倒计时后伴奏/人声/视频共同起点和声学同步、中断接唱/暂停恢复、实际摄像头方向/比例、AirPods/设备麦克风、真实 Files/剪贴板交互、TXT 触摸滚动，以及缩放窗口/大字号/iPhone 实际排版。没有重跑媒体全套或多设备矩阵；沿用先前离线媒体证据，不扩展成设备结果。

按 [IPAD_RETEST.md](IPAD_RETEST.md) 完成短实机复测；V1 硬件 gate 仍为 IMPLEMENTED_UNVERIFIED。
