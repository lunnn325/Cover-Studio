# iPad 横屏启动/恢复交互证据

代码 `14fe7fa52d0c39c3b99863859986ccbde1f7039b`，[Actions 40077917116](https://github.com/lunnn325/Cover-Studio/actions/runs/40077917116)，job `120825198330`，整体成功。50 项核心 XCTest、arm64/x86_64 无签名编译及 **1 条 iPad 原生 UI test** 通过。设备 iPad Pro 13-inch (M5) Simulator / iOS 26.4.1 / arm64；测试先设横屏并断言实际窗口宽大于高。

用例实际点击启动日志保留确认、作品库、上一版索引校验、创建独立副本、安全原件和设置中的保留日志。结束后独立读取模拟器目录：原件/坏索引哈希不变、保留日志一致、pending marker 清除、仅生成一个新副本。见 `scope.json`、`fixture.json`、Apple `summary.json`、`xcodebuild-test.log`、`swift-tests.log` 和 `toolchain.txt`。

## 交互与图片结论分别记录

本次六张原始 `XCUIApplication.screenshot()` 附件保存在 `app-region-capture-limited/`，未经更改。原始 PNG 为 2752×2064、EXIF orientation 8，并有黑色边缘和裁剪，**不能证明完整页面排版通过**；成功的控件/文件断言不因此扩大为图片通过。

为诊断截图和实际屏幕的差异，复用第一次 iPad run `40076883156` / `ce291f3` 已有的 XCTest 自动屏幕录像。完整录像没有上述黑边，当前恢复页面和弹层可见。`earlier-run-video-frames/` 保留六个真实帧，只将完整像素逆时针旋转 90 度以便阅读，没有裁剪、缩放或修改内容；提取命令、偏移秒数、源视频及 artifact SHA-256 见 [provenance.json](earlier-run-video-frames/provenance.json)。这些不是最新成功 run 的截图，也不是相机录制证据。

| 录像偏移 | 已人工查看的有限内容 |
|---|---|
| 32 秒 | 启动错误、保留日志说明与入口，完整屏幕无黑边 |
| 57 秒 | 作品库中正常作品与待恢复目录 |
| 68 秒 | 上一版校验结果与创建副本入口；弹层内其余内容需滚动 |
| 88 秒 | 新恢复副本与原坏目录仍在 |
| 95 秒 | 坏安全索引的原件页已打开，文件行在当前视口底部，不能据此判断行内全部控件 |
| 110 秒 | 设置弹层的录制/高级部分；日志入口在下方，非缺失 |

第一次 run 在最后设置日志入口查找失败；hierarchy 显示前景设置 List 只实例化了可见行。修复为先滚动当前设置列表再断言目标，保留原点击/文件校验后，最新 run 全流程成功。第一次失败不改写为成功；上述帧只支持其已显示页面的浅色、正常字号横屏观察，不覆盖深色/大字号、编辑工作台或录制栏。

后续测试采集已改用 `XCUIScreen.main.screenshot()` 以采集整个显示区域；该辅助改动后未再次编译或运行 UI target，不宣称截图问题已获运行验证。常规应用构建不编译这个测试 target。

成功 artifact `12554590406`，ZIP SHA-256：
`f0f9abd2907cba207fb5eeb59a917383154b0071f6d40e42e82c3593f7cbcc2b`。

第一次 artifact `12553537811`，ZIP SHA-256：
`f0495efbd81cf7ddbc8e887ec81a602d8d85751c418680484a44147dbc13b7c4`。

## 不覆盖的验收

fixture 仅为 Debug Simulator 独立 tmp 目录的明确非媒体文本字节，没有 Take、声音或同步。Release/设备不含 fixture，设备 UI test 直接跳过。本轮没有运行媒体管线；复用既有两秒离线导出/预览结果。

`8669e13` 的会话控制锁/固定停止栏另在 [Actions 40077636598](https://github.com/lunnn325/Cover-Studio/actions/runs/40077636598) 通过核心测试和双架构编译，且已包含在最新 iPad 代码中；本用例不进入录制，**没有验证锁、停止、真实麦克风/相机、AirPods、声学同步、Files 提供者或跨设备迁移**。所有对应 P0 真机 gate 仍为未验证，V1 未标记完成。
