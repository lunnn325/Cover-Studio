# Release 设备 IPA 交付

用户要求沿用 William Lecture 的 GitHub macOS 路径生成 IPA。已核对 WL 实际脚本，使用同样的 Release/iphoneos + 无签名构建 + Payload 打包流程，未改产品或接入证书。

代码 `0b078d150daefd45281aca5d6ddb8660c2f94f64`，[Actions 40090776593](https://github.com/lunnn325/Cover-Studio/actions/runs/40090776593)，job `120862805922`，整体成功：50 项核心 XCTest、Release arm64 设备编译、打包与产物上传。模拟器编译、UI 和媒体步骤均跳过，复用既有证据。

- 文件：`dist/MyCoverStudio-V1-unsigned.ipa`，1,435,900 字节。
- 版本：1.0 / build 1；bundle ID `studio.mycover.app`。
- 最低 iOS/iPadOS 17.0，iPhone/iPad device family 1/2。
- 实际 Mach-O：arm64、LC_BUILD_VERSION platform 2（iOS device）；不是模拟器包。
- ZIP CRC、目录结构、权限说明、无 profile/签名目录检查通过。
- IPA SHA-256：`ade9093bbd417310f8e38203962af4bc217e0c58dae075c2dcde8962382a3d56`。

下载到 Windows 后重新读取 IPA 校验，元数据和 SHA-256 与 CI 报告一致。`ipa-report.json` 保留 CI sourceCommit，未以本地校验覆盖它。

IPA artifact `12559077270`，ZIP SHA-256 `f17700fe187caf4ea283588e58147854f3e5f3475d0fd419e8516424b967cf76`，保留 14 天。构建日志 artifact `12558718298`，ZIP SHA-256 `1f1ce3bd7b1ad069b9af49c712806919cbf085f8eabbfdddb087a8042a8de7fc`。这里的 ZIP 摘要是 Actions 外层 artifact，和内部 IPA 摘要分别记录。

这是需要用户本地签名的 **unsigned IPA**。没有读取 Apple ID、证书或 Secrets，不宣称已安装。此前“缺少签名就不能生成 IPA”的判断已纠正；签名是安装条件。真实录制、AirPods、同步、来电/后台、Files 提供者及跨设备迁移仍未验证，V1 未标完成。
