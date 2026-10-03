# v0.1.37 正式发布记录

2026-10-03。**GPT TouchBar HUD v0.1.37 / Build 40 已正式发布并设为 Latest。** 本版修复重置预告的日期、时区、截止时间和适用范围解析，合并重复公告，并避免升级或恢复运行后补发过时提醒。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.37)；注释标签指向源码提交 `e1378efaae30e0c20b338b8764edfdbe14e7c090`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37094561889)的来源检查、四个回归作业及两个打包作业全部成功；[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37094999632)成功复用并核验同一提交、同一轮次的 Apple Silicon 与 Intel 产物。
- Release 于 `2026-10-03T03:59:34Z` 公开，非草稿、非预发布；Latest 状态与正文一致性已在独立下载核验时确认，四份预期附件齐全。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `GPT-TouchBar-HUD-0.1.37-arm64.dmg` | 3,781,757 | `50ccd67ecf9dc0299e797967de3e6bc07266ea8dbed1da05e7125f7edd0cf85c` |
| `GPT-TouchBar-HUD-0.1.37-x86_64.dmg` | 3,913,048 | `19d6d3fd7cefad72bd69bf4fef455152ad380728d760abd453b4e9c49b84e12b` |
| `SHA256SUMS.txt` | 201 | `9089c5fbdeb1748857a7767998116089d4bb4d1831897f91796e0101e06c9287` |
| `build-manifest.json` | 4,010 | `4bd2fad7acb6e2f381749550bbb67419c45d3d4486a500aa5534ceba4c9f7e4d` |

上述附件使用 `scripts/verify-public-release.py` 从公开 Release 重新下载，与 GitHub 摘要、大小、合并校验文件及构建清单逐项比对。源码提交、构建来源、版本 0.1.37 / Build 40、应用标识、主程序与 helper 架构、macOS 11.0 最低系统标记、DMG 完整性、只读挂载、严格签名和首次打开助手 CDHash 绑定均通过；挂载卷已卸载。

[机器可读核验清单](validation/release-0.1.37-publication.json)保存公开附件及 CI 来源结果。原始下载文件和验证输出保存在本地 `build/release-evidence/public-v0.1.37-4eqCCD/`；本地回归结果见[发布准备](RELEASE-PREPARATION-0.1.37.md)。

## 验证边界

Apple Silicon 与 Intel 的构建和回归均由 GitHub Actions 验证；真实 macOS 11、实体 Touch Bar / 刘海完整场景及正式安装路径的升级重启仍需相应设备验收。安装包使用 ad-hoc 签名，未经 Apple 公证；本次发布及下载核验没有替换或启动本机已安装应用。
