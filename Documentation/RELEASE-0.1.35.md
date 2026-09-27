# v0.1.35 正式发布记录

2026-09-27。**GPT TouchBar HUD v0.1.35 / Build 38 已正式发布并设为 Latest。** 本版修复 GitHub Release API 限流时，更新检查未尝试可用 Release 页面的行为。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.35)；标签指向源码提交 `e7b38ef3eeb88103eb36ba17a9e2973da294a699`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/36318698622)与[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/36319464029)均成功。标签工作流复用并验证该提交的 Apple Silicon 与 Intel 构建，没有重新编译或回退到其他源码。
- Release 公开、非预发布，说明与标签提交中的 `RELEASE_NOTES.md` 一致，四份预期附件齐全。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `GPT-TouchBar-HUD-0.1.35-arm64.dmg` | 3,628,959 | `ac1ab892e2e288db455985bc8df9f790daa0eb27a0fe1b36ce163620a5a78ff7` |
| `GPT-TouchBar-HUD-0.1.35-x86_64.dmg` | 3,741,018 | `97d39a6fecc0cd44b7bd0af7222dd4bebd8d56f69e1664efd6e278eeb2910f64` |
| `SHA256SUMS.txt` | 201 | `345e7a71498b0d4a0a33cf0de9544aae48f20c91660ea169ad56c1022724f5be` |
| `build-manifest.json` | 4,010 | `a9506f4266ede7440bee9829f64cea5b8fb96bc3cd5841daec60948d8d23fcb5` |

上述附件从公开 Release 重新下载，逐一与 GitHub 摘要和大小比对；两份 DMG 另与 `SHA256SUMS.txt` 和构建清单核对。DMG 完整性、只读挂载、包内版本 0.1.35 / Build 38、应用标识、主程序及 helper 架构、macOS 11.0 最低系统标记、严格签名与首次打开助手 CDHash 绑定均通过。挂载卷已卸载。[机器可读核验清单](validation/release-0.1.35-publication.json)保存来源和附件结果，下载文件保存在本地 `build/release-evidence/publish-0.1.35/`。

## 更新检查验证

- 更新策略测试 90 项、发布流程来源与拒绝规则 64 项通过。本地 arm64 v0.1.35 候选包通过版本、架构、最低系统标记和签名检查。
- 修复候选在 API 匿名额度耗尽的真实网络环境中，通过 Release 页面读取到当时的 v0.1.34；安装后手动检查显示“无需更新”。v0.1.35 发布后，当前已安装的 v0.1.34 应用手动检查成功显示 v0.1.35 版本说明及安装选项；本次选择“稍后”，未安装公开新版本。

## 边界

Intel 构建由 GitHub Actions 的 Intel runner 验证。下一次后台定时检查、正式安装路径的自动升级重启、真实 macOS 11 运行及实体 Touch Bar / 刘海完整场景仍待相应设备验收。安装包为 ad-hoc 签名，未经 Apple 公证。
