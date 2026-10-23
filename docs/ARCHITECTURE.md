# 技术架构与实现约束（Codex 可优化）

## 1. 推荐技术路线

- Swift / SwiftUI 原生通用 iPhone+iPad App，现代 async/await + 明确 actor/task 生命周期；文件系统数据与轻量索引分开。SwiftUI 可采用 MVVM/feature-coordinator，只要依赖清晰。
- AVFoundation + AVFAudio 管理 capture、播放、处理、编辑和输出；CoreMedia 提供时间信息；系统 PhotosPicker、FileImporter/FileExporter 或 UIDocumentPicker 使用当前推荐 API。
- 对 AI 分离、逐字歌词、自动修音各定义**可拔插协议/Capability Provider**，不存在支持能力时明确禁用，不让第三方模型主导 P0 架构。
- 第三方库需查 license、维护状态、CPU/内存/iOS 兼容性，纳入 `THIRD_PARTY_NOTICES`；不得默认“GitHub 上有模型就能移动端免费商用”。

## 2. 关键模块

`AppCoordinator` → `SongRepository` / `ProjectRepository` → `ArrangementService` → `PlaybackPitchEngine` → `RecordingCoordinator`（camera+mic+playback+route/timebase）→ `TakeStore` → `EditingGraph` → `ExportQueue` → `ArchiveManager`；`AISeparationProvider` / `LyricsAlignmentProvider` / `PitchCorrectionProvider` 为可选插件。

### RecordingCoordinator

- 不允许相机录音和 AVAudioEngine 同时不受控地争抢麦克风；明确选择**单一麦克风捕获路径**并与视频捕获统一同步锚点。具体采用 `AVCaptureAudioDataOutput` 或音频引擎输入需实机评估。
- 进入录制前配置/激活音频会话，检查实际路由；选择蓝牙高质量功能时受系统模式及设备能力限制，HFP 是明确的回退；任何输入变更后再次校验输出，必要时暂停用户确认。
- 对 AirPods 高质量路线默认关闭人声耳返；播放伴奏仍尽可能留在耳机。蓝牙双向连接和低延迟不能假设自由同时成立。
- 记录音频/视频实际采样时间戳、歌曲播放位置与 route transition；维持统一单调时间基准，支持固定时间偏移的可逆校准。不可“播放、录像各自 start() 即假设完全同步”。
- 状态机：`idle → preflight → ready → countdown → recording ↔ paused/interrupted → finalizing → saved/recoverable_error`。状态跃迁幂等、可追踪。中断后新片段作为新节点，拼接由工程编辑层完成。
- 录像/人声分别持久化；评估 fragmented QuickTime MOV 或短片段容器、首片段较短间隔，后台和崩溃尽力恢复。选择受支持格式后不要声称 MP4 也天然支持所有同样的分片崩溃保护。
- 实际剩余空间采用动态预估：当前码率、可写空间、完成文件开销、日志与导出临时空间。非危险先提醒，危险状态安全停止但不删除。

### Arrangement & AI

- 歌曲身份、原始音频、原唱与伴奏双 stem、变调半音、歌词映射分离保存。换分离模型只创建新 Arrangement 和音频资源，不能改旧 Take 的来源指针。
- `AVAudioUnitTimePitch` 等支持独立变调；100 cents/半音，保持 rate 1.0，变调音质在目标范围试听。播放与离线导出应使用一致的变调配置，避免导出与监听不同调。
- iPad AI 模型基于设备 RAM/存储/速度选型；可按需下载并手动删除，真实进度采用工作单元/阶段，如果无法提供精确百分比则显示不确定进度而非假值。
- AI“去除强度”可以通过不同模型结果比较或混回原唱 stem 的音量实现，但不得把混回误称成 AI 模型去除能力增强。
- 免费云端 provider 默认为未配置：只有找到授权的可维护服务并取得明确用户上传同意才开启；无持续费用承诺需谨慎，不能虚构永远免费。

### Lyrics & Correction

- LRC 逐句是基础；没有逐字时间戳不猜测精确字时刻；已有原唱/本人录音可尝试强制对齐，置信度不足逐句或手动校正。
- 音准修正必须实现音高估计+音乐调性/目标音+局部修正、保留非稳态音特征；前后 A/B + 默认关闭；不把整轨 pitch shift 伪装成自动修音。

### Editing / Export

- 保存操作（选定 Take、EQ 参数、音量、字幕样式、同步偏移、裁剪）为**无损编辑图**，原始素材只读；最终混音/视频组合是派生物。
- 支持双视频变体复用音频混音与无字幕基底，导出顺序队列可恢复；失败仅影响该导出项。目标路径和临时磁盘占用要记录、预检。
- 录制预览直接消费已经 finalize 的 Take，不以正式字幕、4K 渲染作为预览前提。

## 3. 安全性与隐私

- 媒体数据本地保存、隐私权限使用时解释用途；不包含第三方分析 SDK、不上传人声/视频到自建服务器。
- 若用户选择云端 AI，在本地明显展示即将上传的文件类型、服务方、用途及隐私风险，收到同意后才上传；上传失败不删除本地。
- 文件导入进行格式、长度、大小、路径遍历与恶意压缩包安全校验；Zip 不能允许 `../` 路径写出沙盒、压缩炸弹、同名覆盖。
- 元数据和日志不要保存用户私人声音转录；只保留必要错误码与非敏感状态。

## 4. 平台与可安装构建

- 可在 Windows 用 Codex 开发 Swift 项目，但 Xcode 构建需要 macOS 运行环境（例如 GitHub-hosted macOS runner）；不等于无需真实 Apple 签名材料就能生成可侧载 IPA。
- CI 建议手动 `workflow_dispatch` 或明确里程碑触发；区分不签名编译产物、可安装签名 IPA。签名凭据通过 Secrets，不能写入仓库。
- 使用 SPM 等轻依赖方案；如确定使用生成 Xcode 工程的工具，必须提供可复现构建、锁定版本与清晰步骤。
- 兼容性列表中注明系统版本、设备能力与硬件限制。未实机验证不打勾。

## 5. 工程自检与未来优化

- 必须允许以更优 API、媒体管线或依赖替代本建议，但在 `IMPLEMENTATION_ADR.md` 说明：变更原因、预期收益、与 14 轮用户决策兼容性、数据迁移方案、如何验证。
- 不要为追求所谓“完美架构”引入多个后端、数据库同步平台或耗时 CI 矩阵。
