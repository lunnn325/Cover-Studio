# 启动与恢复的原生 UI 验证

代码 `136103c7419909d03d1e8659b359f84fedf99a17`，[Actions 40075596762](https://github.com/lunnn325/Cover-Studio/actions/runs/40075596762)，job `120818131493`，整体成功。

50 项核心 XCTest、arm64/x86_64 无签名应用编译，以及 **1 条原生 UI test** 通过。UI 使用 iPhone 17 Pro Simulator / iOS 26.4.1 / arm64，Xcode 26.6 / Swift 6.3.3（Swift 5 语言模式）；测试阶段统一使用 runner 原生架构，前置双架构编译仍保留。

UI test 实际点击控件及保留确认，未直接调用恢复 handler。六张截图已人工查看，错误说明、确认后的索引状态、原件及日志内容可见且可读：

| 截图 | 实际页面 / 结果 |
|---|---|
| [01](01-startup-failure.png) | 根事务错误页，重试、日志大小/哈希及保留入口 |
| [02](02-library-with-damaged-index.png) | 保留日志后打开库，正常作品与坏索引分别显示 |
| [03](03-verified-previous-index.png) | 上一版索引/素材校验结果和创建副本入口 |
| [04](04-recovered-copy-original-still-listed.png) | 恢复副本已生成，原坏目录仍列出；图为当时列表视口 |
| [05](05-safety-originals-with-invalid-index.png) | 坏安全索引目录的原件列表实际打开，可看到独立原件及索引文件 |
| [06](06-retained-startup-log.png) | 设置中的保留启动日志和另存入口 |

结束后由 Python 独立读取模拟器文件核对：原件/坏索引哈希不变、仅原 marker 被保留为同 SHA-256 日志、pending marker 清除、生成 1 个新工程副本。见原始 `scope.json`、`fixture.json`、Apple `summary.json` 和 `xcodebuild-test.log`；核心日志也已保留。

这是 Debug Simulator 独立 tmp 目录内的生成 metadata/文本字节 fixture；不是音视频，不含 Take，不支持声音/同步/录制验收。Release/设备不含 fixture 路径，UI test 在设备跳过。未实际导出到 Files 提供者、播放原件或迁移另一设备，也没有测试 iPad/深色/大字号或整套产品交互。

本轮发现并修复：

- `5293630` / run `40073717700`：核心测试及首次双架构编译通过，UI 测试阶段 app 与 CoverCore.o 架构不一致，0 条 UI test 运行；统一测试架构后解决。
- `dddd9e8` / run `40074400656`：UI 已完成保留与索引副本恢复，但原件浏览入口未打开，留下四张真实截图；改为现有存储导航栈打开原件，同行按钮使用独立命中样式，保留原断言后全流程通过。没有将部分执行算作成功。

成功 artifact `12553795326`，ZIP SHA-256：
`c74a93707b4aa35bafec4839c30a2e94ac019fe92f4cde3a4787b3afacc9764b`。

前两次失败 artifact `12552437871` / `12552604320`，ZIP SHA-256 分别为：
`37a5b5f172d723564308407ca87800a41fdee7b6c15b7118fc48e68862037543` / `7fa67eb34426d8a9a53a18dd5a8568169720e53a17bd6b9abe148d85d82a0984`。

本轮不重复离线媒体引擎检查，复用已有导出/预览/描边证据。签名、AirPods、相机、真实录制/声学同步、系统中断和 Files→iPad 实机验收仍未通过，不将 V1 标记完成。
