# v0.1.40 正式发布记录

2026-10-06。**GPT TouchBar HUD v0.1.40 / Build 43 已正式发布并设为 Latest。** 本版修复额度连接失败或意外中断后的恢复、更新结果窗口关闭后的无效轮询和额度窗口误分类，初始化时读取当前构建版本。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.40)；注释标签指向源码提交 `5f1dd22b19c541678cd1e7f311dbbac7dd6067de`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37402657502)的来源检查、四个回归作业和两个打包作业全部成功。[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37403403410)成功复用同一提交、同次运行和 attempt 1 的 Apple Silicon 与 Intel 产物。
- Release 于北京时间 2026-10-06 10:18:31 公开，非草稿、非预发布。Latest 状态与正文均经独立核验，正文和标签提交中的 `RELEASE_NOTES.md` 完全一致。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `f39129fa576f1120e829205a74f95247d1634d57bd7f472e642264a016bb5b34` |
| `GPT-TouchBar-HUD-0.1.40-arm64.dmg` | 3,969,037 | `b44eb3821251a4b3723114c384f30dc7c6e12b7f78b12b43da9d94b29725f0fc` |
| `GPT-TouchBar-HUD-0.1.40-x86_64.dmg` | 3,968,450 | `0af8203878845897087af9548af627bd3a8b03a974f2d9e3a98281294a448006` |
| `SHA256SUMS.txt` | 201 | `bab2d60535293a36e1d2f39da42cf7792ccde6412bc6845cdc43fbd923bfce87` |

使用 `python3 -B scripts/verify-public-release.py v0.1.40` 从公开 Release 重新下载四份附件，逐项核对 GitHub 摘要、大小、合并校验文件和构建清单。源码及同次构建来源、版本 0.1.40 / Build 43、应用标识、主程序与 helper 架构、macOS 11.0 最低系统标记、DMG 完整性、只读挂载、严格签名及首次打开助手 CDHash 绑定全部通过；挂载卷已卸载。

[机器可读核验清单](validation/release-0.1.40-publication.json)保存公开附件与 CI 来源。下载文件和原始验证结果保存在本地 `build/release-evidence/public-v0.1.40/`。本记录在标签发布后提交，不改变上述发布二进制的源码来源。

## 验证范围

本地修复及异常路径验证见[工程修复记录](ENGINEERING-FIXES-2026-10-06.md)，版本准备见[发布准备](RELEASE-PREPARATION-0.1.40.md)。Apple Silicon 和 Intel 的完整回归与打包均由上述 CI 验证。真实宿主长期使用、休眠唤醒、真实 macOS 11、实体 Touch Bar / 刘海及正式安装路径的升级重启仍需实机验收。安装包为 ad-hoc 签名，未经 Apple 公证；本次发布和公开附件核验没有替换或启动本机已安装应用。
