# V1 实施与验收状态

日期：2026-10-24（Asia/Singapore）。分支 `codex/my-cover-studio-v1`，草稿 [PR #1](https://github.com/lunnn325/Cover-Studio/pull/1)。产品要求未重新访谈；技术优化见 IMPLEMENTATION_ADR.md。

这是已实现并进入集中验证的原生开发版本，**不等于完成全部实机验收**。没有 Apple 签名凭证、已签名 IPA、iPhone/iPad 真机或 AirPods 测试证据。

## 构建证据

- Windows：确定性 Xcode 工程、权限、隐私、图标和源文件收录检查通过。
- [run 40035445456](https://github.com/lunnn325/Cover-Studio/actions/runs/40035445456)，`eba4cc3`：19 项核心测试及无签名 iOS 编译通过。iPad 浅/深和 iPhone 深色空状态可见；首次 iPhone 浅色截屏过早为空白，不计通过。
- [run 40036337745](https://github.com/lunnn325/Cover-Studio/actions/runs/40036337745)，`6597013`：20 项核心测试及编译通过；离线媒体 smoke 未在 120 秒内完成，**失败**，不能声称导出已通过运行验证。
- `feefa40` 暴露新增存储页 SwiftUI 类型检查超时，已拆分表达式修正；`795f2f2` 编译通过，但媒体进程在字幕阶段退出。随后改为 Core Image 逐帧字幕，双视频和音频实际生成。
- `690af59` 的独立频谱检查捕获变调音频实际采样率错误（240.417 Hz，而非预期 261.626 Hz），已修正 effect 两侧格式及 offline 构图时机，未放宽阈值。
- **[run 40042964676](https://github.com/lunnn325/Cover-Studio/actions/runs/40042964676)，`b3bfcdf`：全部成功。** 23 项核心 XCTest、arm64/x86_64 无签名编译、五种两秒真实导出、中英文字幕帧和工程包恢复通过；独立 FFT 得到 261.658 Hz，时长两秒，干声仍 440 Hz。[保留的小报告与输出帧](validation/2026-10-24/README.md)。只验证隔离合成素材离线路径，不代表硬件采集或真人听感。
- **[run 40044401370](https://github.com/lunnn325/Cover-Studio/actions/runs/40044401370)，`f569647`：编辑预览增量检查成功。** 23 项核心测试及双架构编译通过；1.5 秒方形裁剪/镜像、中英文预览帧、源哈希、原队列不变与缓存释放通过。[预览证据](validation/2026-10-24-preview/README.md)。复用上述成品/工程恢复结果，未重复运行；原生交互播放器与设备听感仍待验。
- **[run 40047238677](https://github.com/lunnn325/Cover-Studio/actions/runs/40047238677)，`9480730`：28 项核心测试及双架构编译通过。** 新增历史成品保留、未登记可信度、删除边界、带成品包恢复、自定义输出依赖和源释放保留成品检查；本轮未启动模拟器。[目录/备份证据与日志](validation/2026-10-24-catalog/README.md)。UI 操作与真实文件提供者仍待验。
- 后续补丁和每次实际结果见 DEVELOPMENT_LOG.md；具体 commit 的通过结果不能自动推广到未测试改动。
- **[run 40049498575](https://github.com/lunnn325/Cover-Studio/actions/runs/40049498575)，`f3b6b23`：33 项核心测试及双架构编译通过。** 复制保留未登记文件/历史成品、哈希失败保留暂存、不重新开麦结束接唱、尾段/日志完整包恢复、原件登记/删除边界通过；未启动模拟器。[恢复证据与日志](validation/2026-10-24-recovery/README.md)。保留尾段字节不等于修复为可播放或同步录音。
- **[run 40070002495](https://github.com/lunnn325/Cover-Studio/actions/runs/40070002495)，`ab45992`：34 项核心测试、双架构编译和描边帧增量通过。** 新增描边/旧工程兼容/必需功能标志；第一次帧检查发现宽描边遮掉填充，改为先描边后填充后通过，断言未放宽。实际中英文帧、独立像素计数、队列/源哈希/缓存结果见[描边证据](validation/2026-10-24-outline/README.md)。未重复全导出或实机验收。

## P0 核心

`IMPLEMENTED_UNVERIFIED` 表示代码路径已实现，但未完成对应真实设备验证，不能按 QUALITY_GATES 标 PASS。

| Gate | 实现状态 | 范围与必要验证 |
|---|---|---|
| P0-01 伴奏/变调/歌词 | IMPLEMENTED_UNVERIFIED | Files 导入 MP3/M4A/WAV、哈希/时长、±12 半音 rate 1、A/B 试听、TXT/LRC 与手工逐句时间点。需真机检查格式/音质 |
| P0-02 单机镜头/麦克风/路由 | IMPLEMENTED_UNVERIFIED | 唯一 AVCapture 麦克风路径、前/后镜头、纯音频备用、实际路由与输入选择。未验证 AirPods 声学表现 |
| P0-03 倒计时/原始素材/同步 | IMPLEMENTED_UNVERIFIED | 3 秒倒计时、独立干声/视频、共同 host 时间基准与 firstPTS/路由信息。实际声学偏移需试听校准 |
| P0-04 路由变化 | IMPLEMENTED_UNVERIFIED | 通知时停伴奏/耳返并保存片段；恢复需确认输出，不自动继续。代码审查不能证明硬件零外放瞬态 |
| P0-05 多 Take/立即预览 | IMPLEMENTED_UNVERIFIED | UUID 素材、逐段提交、原始干声/画面预览、练习转正式保留原件、记忆选中 Take |
| P0-06 混音/字幕 | IMPLEMENTED_UNVERIFIED | 音量、EQ、高通降噪、混响、固定偏移、字幕样式/范围、独立黑色描边宽度、镜像/裁剪和会话撤销；导出前画面/字幕预览、描边帧与缓存/数据保护检查通过。高通不是完整环境降噪 |
| P0-07 1080p 输出 | IMPLEMENTED_UNVERIFIED | 双视频顺序导出，M4A/WAV 混音/干声/伴奏、歌词、分项重试、App 内成品播放，照片或独立补拍。两秒 MP4/WAV 路径已通过；仍需真实听看验收 |
| P0-08 中断/低空间 | IMPLEMENTED_UNVERIFIED | 约 8 秒片段 + MOV fragment、journal、空间/热保护和后台暂停；不重新开麦可保留日志/尾段字节后结束接唱。最后未封装片段可能无法恢复可播放或同步 |
| P0-09 完整工程迁移 | IMPLEMENTED_UNVERIFIED | 字节/哈希/依赖/版本纯逻辑测试已过；真实 Files→另一台 iPad 编辑/导出尚未测试 |
| P0-10 精简/自定义/冲突 | IMPLEMENTED_UNVERIFIED | 依赖闭包、自定义逐个选择历史成品、并存或保留安全目录再替换、事务回滚；选择变化后旧包失效。依赖/包恢复测试已过，设备空间不足场景待验 |
| P0-11 云/归档 | IMPLEMENTED_UNVERIFIED | 分离打包/Files接收/恢复验证，列出排除 Take，二次确认；待恢复录制阻止源释放，源释放保留成品。目录支持历史及未登记文件的预览/分享/单独删除，UI 与真实 Google Drive 提供者未测 |
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
- 字幕为逐句烧录，不是逐字卡拉 OK；提供字体/大小/白色或黄色/阴影/位置/范围及独立黑色描边宽度。中英文短帧已检查，长歌词与真机观看未验收。
- 临时缓存和导出需要本地空间；改 Files 目标不会消除最低渲染空间，没有直接云渲染。
- 安全副本/失败恢复暂存不自动清理；存储页显示占用，可校验导出副本工程包，或两次确认移除指定副本。损坏且无有效索引的暂存无法保证可打包。
- 真实安装需要合法 Apple Team/证书/描述文件，尚未提供，当前无可安装 IPA。

## 最小真机验收（尚未执行）

用 30–60 秒自有伴奏，在 iPhone + AirPods 和设备麦克风各录两次：确认输出、停止/预览、选择旧 Take、导出带/无字幕，检查同步。再测试断线、来电、后台和空间保护，记录设备/系统/AirPods型号/实际路由与结果。

下一次从 Xcode 配置真实 Team 并安装到设备开始，按上述短样本核验；当前代码已通过集中检查，普通文档更新不再重跑 Actions。未取得设备或签名条件前，不能把这些 gate 标为 PASS。

将完整包保存到真实 Files 提供者，重新打开校验，在另一台 iPad 恢复编辑/导出，再检查精简/自定义、冲突并存/安全替换和二次确认。没有记录则维持未验证。
