# 字幕描边增量验证

## 捕获的实际失败

`10bbd4cbd89158fc5b59b5a111f47c48ffa5a4f6` / [Actions 40069519760](https://github.com/lunnn325/Cover-Studio/actions/runs/40069519760)，job `120799730523`：34 项核心 XCTest 与双架构无签名编译通过，但新增描边帧检查失败。

实际 [失败帧](failed-outline-before.png) 显示宽描边覆盖了细笔画填充。下载帧经独立 NumPy 计数：边缘变暗 886 像素，白色填充从未描边的 291 像素降为 0。该结果不能按可读描边通过；保留原断言，改成先画纯描边、再恢复完整文字填充。

失败 artifact `12550845979`，ZIP SHA-256：
`4c568febcd76849e02959652ab99d275add16c3b6142bed3c3522757e17f66d7`。

## 修复后通过

`ab459920775a68e1fbf086789ac9ae4f1b96c8c2` / [Actions 40070002495](https://github.com/lunnn325/Cover-Studio/actions/runs/40070002495)，job `120801189993`：34 项核心 XCTest、arm64/x86_64 无签名编译及预览增量全部成功。Xcode 26.6 / Swift 6.3.3，Swift 5 语言模式；iPhone Simulator iOS 26.2。原始测试日志与 `MediaSmokeReport.json` 保留在此目录。

新增核心检查覆盖：旧样式缺省为无描边、描边/阴影参数随完整包往返、`subtitle-outline` 必需功能标志、异常数值/字号/位置拒绝。旧 reader 会拒绝启用描边的新包，避免静默丢失样式。

实际帧已人工查看：[英文](preview-outline-1.png)、[中文](preview-outline-2.png)；对应[无描边英文](preview-subtitle-1.png)、[无描边中文](preview-subtitle-2.png)和[无字幕画面](preview-clean.png)均保留。阴影关闭，仅改变描边宽度为 4 输出像素；下载 PNG 后独立 NumPy 复核：

| 帧 | 边缘变暗像素 | 原填充像素 | 描边后填充像素 |
|---|---:|---:|---:|
| 英文 | 940 | 291 | 218 |
| 中文 | 578 | 246 | 188 |

像素差按同一 360×360 帧的 RGB 门槛计算；不同字形/缩放抗锯齿会影响数量，不作为所有字体或长歌词的通用质量门槛。填充仍可见、边缘变黑，原断言未放宽。检查同时通过 1.5 秒方形裁剪/镜像、源哈希不变、导出队列不变与自身缓存释放。

成功 artifact `12551077195`，ZIP SHA-256：
`1d26ccd441c463191549ce25547080b25223c667f82e299ebc4bd665bbc37669`。

中英文帧比较只覆盖 Core Text / Core Image 字幕叠加，不代表真实录制、交互播放器、真人听感或设备观看通过。没有重复完整双版本输出/音轨/工程迁移检查，复用先前独立证据；P0 实机 gate 保持未验证。
