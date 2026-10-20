# v0.1.46 发布记录

2026-10-20。**GPT HUD v0.1.46 / Build 49 已正式发布并设为 Latest。**

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.46)于北京时间 2026-10-20 17:37:04 公开，非草稿、非预发布；附注标签指向源码提交 `72d64bd08966b908083210b5a970577df74597ce`。
- [main 完整双架构 CI](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/39399791323)的来源校验、四个回归作业、两个打包作业及 CI Gate 全部成功，无重试。两架构安装包均来自 run `39399791323`、attempt `1`。
- [标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/39401911005)复用上述原始产物，未重新编译。公开正文与标签提交的 `RELEASE_NOTES.md` 一致。

## 本版变更

对外展示名称统一为 GPT HUD，README 主图和当前原生菜单截图同步更新，并保存[图片来源与复现说明](../Marketing/README-assets.md)。旧图片及历史发布记录保留。

为保持旧客户端直接升级能力，DMG 资产仍使用 `GPT-TouchBar-HUD-<版本>-<架构>.dmg`，包内应用仍为 `GPT TouchBar HUD.app`；Bundle ID、可执行文件、安装路径、持久数据与辅助服务身份保持不变。当前没有启用应用路径迁移。

安装身份与展示名分开定义；兼容约定和历史客户端夹具已进入正常打包 CI。此前专用于验证分支的临时 Intel workflow 已移除，正常发布门禁保持不变。[升级契约与覆盖边界](UPDATING.md)说明未来独立迁移须等待旧路径更新事务确认，不能在旧安装器回执前移动应用。

## 验证

本地兼容契约、Info.plist、发布工具回归与 diff 检查通过；独立发布审查未发现阻塞问题。README 九张引用图已核对，新主图与原生菜单截图完成目视校验。

本次正式构建在原生 arm64 与 Intel/Xcode 26.3 runner 均完成完整数据、界面回归及打包。每个正式 DMG 均执行兼容契约、真实 v0.1.22 模型测试和真实 v0.1.38 源码夹具：有效包准备、错误校验和/版本/签名拒绝、旧路径回执边界、旧 Bundle 安装器复制、隔离安装成功及回滚、超时清理均通过。

公开后运行 `python3 scripts/verify-public-release.py v0.1.46`，重新下载全部四份附件。Latest、正文、标签源码、同次构建来源、清单、大小与 SHA-256、DMG 完整性、只读挂载、展示名 GPT HUD、旧应用文件名、Bundle ID、旧可执行文件、版本 0.1.46 / Build 49、App/Helper 架构、macOS 11.0 最低标记、严格签名及首次打开助手 CDHash 绑定均通过。只读挂载已卸载。

另将实际公开 Release API 与 `SHA256SUMS.txt` 交给固定源码提交的 v0.1.22、v0.1.38 模型编译运行；两者均识别本次稳定版本为新版本，并接受两个架构的兼容资产及校验和入口。没有使用新模型替代旧客户端验证。

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `0aa31aea3a66375bebc4deba9e34a6044405726e0f4f9a862c8ad6e769c627d6` |
| `GPT-TouchBar-HUD-0.1.46-arm64.dmg` | 4,917,208 | `b2a70cc3edf2c182cea72b8e70660fed584e272ece1b0f313fc2e1f7dc7581c7` |
| `GPT-TouchBar-HUD-0.1.46-x86_64.dmg` | 5,119,770 | `6ad176936f51dd25e2a50adec659278f0959f1b4beb2e9b413ce9a4662826318` |
| `SHA256SUMS.txt` | 201 | `f16c0176d506fab9962cbe4a0342bf7d422ff0b6dbfc62b2804ee6ad28856124` |

[机器可读核验清单](validation/release-0.1.46-publication.json)保存公开资产、构建来源、包内元数据与历史模型结果。本地公开下载位于 `build/release-evidence/public-v0.1.46/`，CI、历史模型及执行记录位于 `.build/release-v0.1.46/`。本记录在标签发布后提交，不改变二进制来源。

## 验证边界

v0.1.22 只覆盖实际历史模型及资产/校验和契约，不代表该版完整安装链通过。v0.1.38 覆盖真实 DMG 的旧准备逻辑及隔离安装/回滚，但应用启动、回执发送和暂停使用测试替身；这不是实际用户已完成自动升级的证明。代表版本的来源和机制差异见[历史夹具说明](../Tests/LegacyUpdateCompatibility/README.md)。

实际 macOS 11 运行、实体 Touch Bar/刘海硬件及真实已安装应用的跨版本自动升级未验证。最低系统标记与双架构 CI 不替代这些实机验证。安装包采用 ad-hoc 签名，未经 Apple 公证。本轮没有替换或启动用户实际安装，也未修改真实 LaunchAgents、preferences 或 hooks。原有三项未跟踪资料保持不动。
