# v0.1.39 正式发布记录

2026-10-05。**GPT TouchBar HUD v0.1.39 / Build 42 已正式发布并设为 Latest。** 本版修复已结束任务被迟到的工具结果或 Token 更新重新计为执行中的问题，统一普通日志与 Hooks 模式的任务状态判定。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.39)；注释标签指向源码提交 `66248bd1eaff04684bc7a0c93e03af2cc84493a3`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37261159159)的来源检查、四个回归作业及两个打包作业全部成功。[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37261739242)成功复用同一提交、同一次运行及同一轮次的 Apple Silicon 与 Intel 产物。
- Release 于北京时间 2026-10-05 12:01:58 公开，非草稿、非预发布。公开正文与用户确认的修订版说明及标签提交中的 `RELEASE_NOTES.md` 完全一致。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `4cde4568eca9fe416d80d9bc6f24c3ef24ab0ed803e811a06d456766257bc128` |
| `GPT-TouchBar-HUD-0.1.39-arm64.dmg` | 3,969,699 | `7cd25b16102e301537e86779c399a97572429947d3667d741d4b84fb2f22aa1f` |
| `GPT-TouchBar-HUD-0.1.39-x86_64.dmg` | 4,115,938 | `fdec6464a0d2cd64188c789701f3f15a5312cadb81f84860b54cc57b81a4aa23` |
| `SHA256SUMS.txt` | 201 | `1f741d17e3c6966e65f3c48a349b88d1bfa0dc61519eb9dd02b3929427598d4b` |

使用 `python3 -B scripts/verify-public-release.py v0.1.39` 从公开 Release 重新下载四份附件，核对 GitHub 摘要、大小、合并校验文件与构建清单。源码提交、同次构建来源、版本 0.1.39 / Build 42、应用标识、主程序与 helper 架构、macOS 11.0 最低系统标记、DMG 完整性、只读挂载、严格签名及首次打开助手 CDHash 绑定均通过；挂载卷已卸载。

[机器可读核验清单](validation/release-0.1.39-publication.json)保存公开附件和 CI 来源。原始下载文件及验证输出位于本地 `build/release-evidence/public-v0.1.39/`。本记录在标签发布后提交，发布二进制来源固定为上述源码提交。

## 本地验证与合并

- 主目录改动提交为 `6cb9195`，生命周期工作树改动提交为 `4785d61`；合并提交为 `a282766`，两组改动均已进入 main。
- 重置预告运行时 278 项检查、任务状态 82 项检查、Hooks 48 个测试、Hooks 集成检查及发布流程检查通过。
- 本地 arm64 候选包构建、严格签名及 macOS 11.0 最低系统标记核验通过。两架构的完整回归与正式安装包由上述 main CI 验证。
- 生命周期工作树保留，相关提交已合入 main；本轮未清理工作树或其忽略文件。

## 验证边界

启动或恢复监测时，缺少可核实的任务开始记录可能暂时少计执行中任务。真实宿主 Hooks 投递、真实 macOS 11、实体 Touch Bar / 刘海完整场景及正式安装路径的升级重启仍需相应设备验收。安装包使用 ad-hoc 签名，未经 Apple 公证；本次发布及下载核验没有替换或启动本机已安装应用。
