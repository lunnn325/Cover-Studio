# V1 实施与验收状态

日期：2026-10-24（Asia/Singapore）。分支 `codex/my-cover-studio-v1`，草稿 [PR #1](https://github.com/lunnn325/Cover-Studio/pull/1)。产品要求未重新访谈；技术优化见 IMPLEMENTATION_ADR.md。

这是已实现并进入集中验证的原生开发版本，**不等于完成全部实机验收**。没有 Apple 签名凭证、已签名 IPA、iPhone/iPad 真机或 AirPods 测试证据。

## 构建证据

- Windows：确定性 Xcode 工程、权限、隐私、图标和源文件收录检查通过。
- 首次 macOS [run 40035445456](https://github.com/lunnn325/Cover-Studio/actions/runs/40035445456)，commit `eba4cc3`：19 项 CoverCore 测试通过，无签名 iOS Simulator application build 通过。模拟器启动证据和最终整合构建结果待更新。
- 首次构建后的补丁包括有线耳返、跨工程操作保护、WAV、字幕范围、补拍偏移、撤销和轻量离线媒体 smoke；不得把首次结果套用为这些补丁已通过。

## P0 核心

`IMPLEMENTED_UNVERIFIED` 表示代码路径已实现，但未完成对应真实设备验证，不能按 QUALITY_GATES 标 PASS。

| Gate | 实现状态 | 范围与必要验证 |
|---|---|---|
| P0-01 伴奏/变调/歌词 | IMPLEMENTED_UNVERIFIED | Files 导入 MP3/M4A/WAV、哈希/时长、±12 半音 rate 1、A/B 试听、TXT/LRC 与手工逐句时间点。需真机检查格式/音质 |
| P0-02 单机镜头/麦克风/路由 | IMPLEMENTED_UNVERIFIED | 唯一 AVCapture 麦克风路径、前/后镜头、纯音频备用、实际路由与输入选择。未验证 AirPods 声学表现 |
| P0-03 倒计时/原始素材/同步 | IMPLEMENTED_UNVERIFIED | 3 秒倒计时、独立干声/视频、共同 host 时间基准与 firstPTS/路由信息。实际声学偏移需试听校准 |
| P0-04 路由变化 | IMPLEMENTED_UNVERIFIED | 通知时停伴奏/耳返并保存片段；恢复需确认输出，不自动继续。代码审查不能证明硬件零外放瞬态 |
| P0-05 多 Take/立即预览 | IMPLEMENTED_UNVERIFIED | UUID 素材、逐段提交、原始干声/画面预览、练习转正式保留原件、记忆选中 Take |
| P0-06 混音/字幕 | IMPLEMENTED_UNVERIFIED | 音量、EQ、高通降噪、混响、固定偏移、字幕样式/范围、镜像/裁剪和会话撤销。高通不是完整环境降噪 |
| P0-07 1080p 输出 | IMPLEMENTED_UNVERIFIED | 双视频顺序导出，M4A/WAV 混音/干声/伴奏、歌词、分项重试，照片或独立补拍。需真实听看验收 |
| P0-08 中断/低空间 | IMPLEMENTED_UNVERIFIED | 约 8 秒片段 + MOV fragment、journal、空间/热保护和后台暂停。最后未封装片段可能无法恢复 |
| P0-09 完整工程迁移 | IMPLEMENTED_UNVERIFIED | 字节/哈希/依赖/版本纯逻辑测试已过；真实 Files→另一台 iPad 编辑/导出尚未测试 |
| P0-10 精简/自定义/冲突 | IMPLEMENTED_UNVERIFIED | 依赖闭包、可选成品、并存或保留安全目录再替换、事务回滚。设备空间不足场景待验 |
| P0-11 云/归档 | IMPLEMENTED_UNVERIFIED | 分离打包/Files接收/恢复验证，列出排除 Take，二次确认。未测真实 Google Drive 提供者 |
| P0-12 无摄像头 | IMPLEMENTED_UNVERIFIED | 权限说明、设置入口和纯音频正式录制，不输出假摄像头画面 |

## P1 与有条件能力

| 能力 | 状态 | 当前行为 |
|---|---|---|
| iPad 双 stem 分离 | NOT_IMPLEMENTED / DEGRADED | Provider 协议存在，无已验证模型；保留原曲，提示导入现成伴奏。无上传 |
| 自动歌词对齐 | NOT_IMPLEMENTED / DEGRADED | LRC 或手工逐句标记，不虚构识别结果 |
| 逐字高亮 | NOT_IMPLEMENTED / DEGRADED | 仅逐句，不按平均字长伪造字时刻 |
| 自动修音 | NOT_IMPLEMENTED | 默认关闭，无整轨变调冒充修音 |
| 智能拼接建议 | NOT_IMPLEMENTED / DEGRADED | 手工切点和后录片段覆盖重叠区，保留原件，画面可能跳切 |
| 4K | DEGRADED | 管线未实机验证，不提供 4K，默认 1080p |
| 高质量蓝牙 | IMPLEMENTED_UNVERIFIED | iOS 26 条件请求并读取系统 supported/enabled，不宣称具体 AirPods 音质已通过 |
| 实时人声耳返 | DEGRADED / IMPLEMENTED_UNVERIFIED | 默认关；仅系统明确有线耳机、格式与延迟门槛满足才开放。蓝牙/未知 USB 禁用 |

## 剩余限制

- 未在真机检验麦克风/镜头权限、AirPods 断线、来电/后台、实际同步和临界空间。不能报告这些 gate 为 PASS。
- 最后一段可能无法封装；重开可使用此前提交的 Take，原文件保留，但不承诺修复所有损坏容器。
- 基础降噪为高通；自动修音、完整环境噪声抑制和逐字对齐未完成。
- 补拍参考从相机开始回调启动，可能有固定偏移；提供独立画面偏移校准，仍需实机验收。
- 字幕为逐句烧录，不是逐字卡拉 OK；提供字体/大小/色彩/阴影/位置/范围，尚无独立描边宽度编辑。
- 临时缓存和导出需要本地空间；改 Files 目标不会消除最低渲染空间，没有直接云渲染。
- 安全副本/失败恢复暂存不自动清理；存储页显示占用，可校验导出副本工程包，或两次确认移除指定副本。损坏且无有效索引的暂存无法保证可打包。
- 真实安装需要合法 Apple Team/证书/描述文件，尚未提供，当前无可安装 IPA。

## 最小真机验收（尚未执行）

用 30–60 秒自有伴奏，在 iPhone + AirPods 和设备麦克风各录两次：确认输出、停止/预览、选择旧 Take、导出带/无字幕，检查同步。再测试断线、来电、后台和空间保护，记录设备/系统/AirPods型号/实际路由与结果。

将完整包保存到真实 Files 提供者，重新打开校验，在另一台 iPad 恢复编辑/导出，再检查精简/自定义、冲突并存/安全替换和二次确认。没有记录则维持未验证。
