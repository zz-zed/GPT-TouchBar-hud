# v0.1.42 正式发布记录

2026-10-12。**GPT TouchBar HUD v0.1.42 / Build 45 已正式发布并设为 Latest。** 本版修复不带任务轮次标识的用量事件使运行任务误变为未知、从计数中消失的问题，并补充任务状态变化原因、解析分类、日志位置与读取异常的诊断记录。重复用量事件采用采样记录，摘要保留未逐条记录的数量。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.42)；注释标签指向源码提交 `9acf390746ae378881a1de80928d712250960fb9`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/38201132759/attempts/2)的来源检查、四个回归作业和两个打包作业全部成功。[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/38203646669)成功复用同一源码提交、同次运行和 attempt 2 的 Apple Silicon 与 Intel 产物。
- Release 于北京时间 2026-10-12 12:24:58 公开，非草稿、非预发布。Latest 与正文经独立核验；正文和标签提交中的 `RELEASE_NOTES.md` 完全一致。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `02c945f33a0a61341c7f00ac0bf9752a116681801bf3d2dd6a6d9a8b34ff0ffa` |
| `GPT-TouchBar-HUD-0.1.42-arm64.dmg` | 4,740,972 | `96f9a9978120f9ff1993a4719e04ffad0328e1e3d2229b1b3eacc68b2a39cc20` |
| `GPT-TouchBar-HUD-0.1.42-x86_64.dmg` | 4,939,578 | `0569929a0b708bb49c33c78ed6257f6f10e084f195a54989002e11cdaf9f019f` |
| `SHA256SUMS.txt` | 201 | `19d2ef907fcec3115053c9ab26bd13a6692445706b11305da5f55cb9dc65e640` |

使用 `python3 -B scripts/verify-public-release.py v0.1.42` 从公开 Release 重新下载四份附件，核对 GitHub 摘要、大小、合并校验文件和构建清单。源码及同次构建来源、版本 0.1.42 / Build 45、应用标识、主程序与 helper 架构、macOS 11.0 最低系统标记、DMG 完整性、只读挂载、严格签名及首次打开助手 CDHash 绑定全部通过；挂载卷已卸载。

[机器可读核验清单](validation/release-0.1.42-publication.json)保存公开附件、构建轮次与发布来源。下载文件和原始结果保存在本地 `build/release-evidence/public-v0.1.42/`。本记录在标签发布后提交，不改变发布二进制的源码来源。

## 重跑与下载记录

首轮构建的工作流汇总显示成功，但 Apple Silicon 打包作业接口持续显示进行中，无法确认该作业的最终成功状态；该轮产物未用于发布。保留原始状态后完整重跑，第二轮七个作业均明确成功，发布仅使用第二轮的两份产物。原始记录保存在本地 `build/release-evidence/pre-v0.1.42-main-ci-attempt1-inconsistent.json`。

首次下载公开附件时发生网络超时，尚未保存任何附件。随后让本次验证命令使用系统已配置的本地代理，重新下载并完成核验；未修改系统代理配置或公开附件。

## 验证范围

Apple Silicon 与 Intel 的完整回归和打包由上述 CI 验证。真实 macOS 11、实体 Touch Bar / 刘海、用户现场长期使用及正式安装路径的升级重启尚未实机验收。安装包为 ad-hoc 签名，未经 Apple 公证；本次没有替换或启动本机已安装应用，其版本仍为 0.1.41 / Build 44，主程序 SHA-256 与发布前一致。
