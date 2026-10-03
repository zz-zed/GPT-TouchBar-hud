# v0.1.38 正式发布与工作树清理记录

2026-10-03。**GPT TouchBar HUD v0.1.38 / Build 41 已正式发布并设为 Latest。** 本版新增原生 Liquid Glass 外观选择、更新下载与安装进度，并将重置预告限定为当前有效信号。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.38)；注释标签指向源码提交 `382f49390ec2cb7b50beceea44307530a862806d`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37106479250)的来源检查、四个回归作业及两个打包作业全部成功；[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37107122918)成功复用并核验同一提交、同一轮次的 Apple Silicon 与 Intel 产物。
- Release 于 `2026-10-03T07:41:02Z` 公开，非草稿、非预发布；Latest 状态与正文一致性已在独立下载核验时确认，四份预期附件齐全。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `GPT-TouchBar-HUD-0.1.38-arm64.dmg` | 3,967,924 | `817ce29833e03d63fabd036716e22c75c9b783c0362c80aae96fa2b3a6402153` |
| `GPT-TouchBar-HUD-0.1.38-x86_64.dmg` | 4,113,871 | `e61fca0792e56edc0cfcb847ea043efab0fb1ea9741cc9a65ed83efa626692b2` |
| `SHA256SUMS.txt` | 201 | `8262506665db5738c42411772cf0094bc1fb1bf7db7b2c760ef96388f4b17a2e` |
| `build-manifest.json` | 4,010 | `1e3597a0a6038a6a4dd9fd3651e2d143094929b03c95c27fc4b703ed6cda6b5b` |

上述附件使用 `scripts/verify-public-release.py` 从公开 Release 重新下载，与 GitHub 摘要、大小、合并校验文件及构建清单逐项比对。源码提交、构建来源、版本 0.1.38 / Build 41、应用标识、主程序与 helper 架构、macOS 11.0 最低系统标记、DMG 完整性、只读挂载、严格签名和首次打开助手 CDHash 绑定均通过；挂载卷已卸载。

[机器可读核验清单](validation/release-0.1.38-publication.json)保存公开附件、CI 来源及工作树清理结果。原始下载文件和验证输出保存在本地 `build/release-evidence/public-v0.1.38-VPXzkl/`；本地回归结果见[发布准备](RELEASE-PREPARATION-0.1.38.md)。本记录在标签发布后提交，发布二进制来源固定为上述源码提交。

## 工作树清理

Liquid Glass 工作树的提交 `2845167bad6c6c0c8fd0adc526a7fe58de660e92` 已是 `main` 的祖先，清理前确认没有未提交代码。170 个非缓存文件共 84,917,118 字节已复制到本地 `backups/worktree-cleanup-20261003-152745-liquid-glass/`，其中包含候选应用、截图、日志和 ZIP；逐文件 SHA-256、文件模式及候选应用严格签名核验通过，容器标记也已备份。完整文件清单见该目录的 `inventory.json`。

清理前已结束该工作树中的隔离材质预览进程，复核进程、打开文件和启动配置没有运行依赖。随后通过 `git worktree remove` 移除工作树及空容器目录；Git 登记只剩主工作树，已合并的本地分支 `codex/liquid-glass` 保留。移除后再次核对备份文件哈希。

清理仅舍弃可重新生成的模块缓存；扣除保留备份后，目录占用净减少约 735.6 MiB，此值不代表 APFS 的实际可用空间变化。主工作树中的试用应用、发布证据和其他资料保留。

## 验证边界

Apple Silicon 与 Intel 的构建和回归均由 GitHub Actions 验证；真实 macOS 11、实体 Touch Bar / 刘海完整场景及正式安装路径的升级重启仍需相应设备验收。安装包使用 ad-hoc 签名，未经 Apple 公证；本次发布及下载核验没有替换或启动本机已安装应用。
