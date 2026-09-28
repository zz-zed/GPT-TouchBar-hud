# v0.1.36 正式发布记录

2026-09-28。**GPT TouchBar HUD v0.1.36 / Build 39 已正式发布并设为 Latest。** 本版增加个人低额度提醒、连接诊断和宿主启动开关；新版本提醒默认开启，并改进 GitHub API 不可用时的页面回退。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.36)；标签指向源码提交 `e79af25eb5e70210b26834b418a8bb7d3f48efcb`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/36421418136)与[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/36423493169)均成功。标签工作流复用并核验该提交的 Apple Silicon 与 Intel 构建。
- Release 公开、非预发布，说明与标签提交中的 `RELEASE_NOTES.md` 一致，四份预期附件齐全。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `GPT-TouchBar-HUD-0.1.36-arm64.dmg` | 3,742,767 | `02643cbaa479e0ba64801cec22b34066bb906ab31021e0de230fba38de433b17` |
| `GPT-TouchBar-HUD-0.1.36-x86_64.dmg` | 3,869,365 | `8d8a08166729977ff9d92e454ebd16a74872834cf0b4b8a7b13599e4ac230e03` |
| `SHA256SUMS.txt` | 201 | `ab6b04c902df93a914fe906cd3f15ecae64c473c7b52fc6c097692b45557cfdc` |
| `build-manifest.json` | 4,010 | `d12cd2ba4934555a82314aab6bcd9fdc291cb556a12c1f0611d5f36663c735d6` |

上述附件从公开 Release 重新下载，逐一与 GitHub 摘要和大小比对；两份 DMG 另与 `SHA256SUMS.txt` 和构建清单核对。DMG 完整性、只读挂载、包内版本 0.1.36 / Build 39、应用标识、主程序及 helper 架构、macOS 11.0 最低系统标记、严格签名与首次打开助手 CDHash 绑定均通过。挂载卷已卸载。[机器可读核验清单](validation/release-0.1.36-publication.json)保存来源和附件结果，下载文件保存在本地 `build/release-evidence/publish-0.1.36/`。

## 更新检查验证

- 本地更新策略测试 90 项、GitHub 故障注入测试 152 项、更新通知测试 61 项、发布流程来源与拒绝规则测试 64 项通过；主线双架构 CI 也通过相应检查。
- 故障注入覆盖 Release API 限流及不可用时的页面回退、无效版本处理和重试行为。公开 v0.1.36 发布后的真实定时提醒与安装升级尚未验收。

## 边界

Intel 构建由 GitHub Actions 的 Intel runner 验证。真实 macOS 11 运行及实体 Touch Bar / 刘海完整场景仍待相应设备验收。安装包为 ad-hoc 签名，未经 Apple 公证；本次发布没有替换或启动本机已安装应用。
