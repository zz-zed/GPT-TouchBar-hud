# v0.1.41 正式发布记录

2026-10-09。**GPT TouchBar HUD v0.1.41 / Build 44 已正式发布并设为 Latest。** 本版新增本地诊断与导出，统一普通日志和 Hooks 的任务状态判断，修复大量日志后任务漏计，并将自动启动、公告解析及缓存读写移至后台。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.41)；注释标签指向源码提交 `2ebb8b1ca9060867c0571657dddc7f2adeef4d3f`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37915317987)的来源检查、四个回归作业和两个打包作业全部成功。[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/37917460247)成功复用同一提交、同次运行和 attempt 1 的 Apple Silicon 与 Intel 产物。
- Release 于北京时间 2026-10-09 18:25:34 公开，非草稿、非预发布。Latest 与正文经独立核验；正文和用户确认稿、标签提交中的 `RELEASE_NOTES.md` 完全一致。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `803af37b940d1434807fe74c92ed37ec5e504750944e3ad43ee5e63885b86fbb` |
| `GPT-TouchBar-HUD-0.1.41-arm64.dmg` | 4,716,781 | `db58ea8ab8419977be63e2c4b52a43d45fb5671b13b725cf806507885d73f3c6` |
| `GPT-TouchBar-HUD-0.1.41-x86_64.dmg` | 4,910,815 | `d4d31dde47064448d8e718b86aa15bdaeb80a137e38c05c7d76e60074910e7d1` |
| `SHA256SUMS.txt` | 201 | `e55fbe40d597fd5bda7dfc5a9f0c197eab603cacd14f3182576eae1e0ae8d927` |

使用 `python3 -B scripts/verify-public-release.py v0.1.41` 从公开 Release 重新下载四份附件，核对 GitHub 摘要、大小、合并校验文件和构建清单。源码及同次构建来源、版本 0.1.41 / Build 44、应用标识、主程序与 helper 架构、macOS 11.0 最低系统标记、DMG 完整性、只读挂载、严格签名及首次打开助手 CDHash 绑定全部通过；挂载卷已卸载。

[机器可读核验清单](validation/release-0.1.41-publication.json)保存公开附件与 CI 来源。下载文件和原始结果保存在本地 `build/release-evidence/public-v0.1.41/`。本记录在标签发布后提交，不改变发布二进制的源码来源。

## 整合与清理

主目录后台改动、诊断工作树和任务可靠性工作树均已提交并合入 main。详情及 CI 修复证据见[工作区整合记录](INTEGRATION-2026-10-09.md)与[验证清单](validation/integration-2026-10-09.json)。首轮到第四轮失败产物均未用于发布；后续修复以本版成功的同源双架构 CI 重新验证。

两棵工作树的 13,992 个文件逐一复制并核验 SHA-256，保留 ignored 缓存、日志和独立 App/ZIP。保全目录为本地 `backups/integration-20261009.noindex/`，含 `inventory.json` 与 `cleanup.json`。确认提交已合入、无依赖进程后移除工作树及临时分支；当前 Git 仅登记主工作树。设计目录中的独立原型仓库保持干净并予以保留。

## 验证范围

Apple Silicon 与 Intel 的完整回归和打包由上述 CI 验证。真实 macOS 11、实体 Touch Bar / 刘海、宿主长期使用及正式安装路径的升级重启尚未实机验收。安装包为 ad-hoc 签名，未经 Apple 公证；本次没有替换或启动本机已安装应用，核验时其版本仍为 0.1.40。
