# v0.1.43 正式发布记录

2026-10-13。**GPT TouchBar HUD v0.1.43 / Build 46 已正式发布并设为 Latest。** 本版修复 `EOD PST`、`end of day PT` 等重置预告截止范围的解析，并换算为本地日期与时间，显示“预计在……前”。界面注明 EOD 按公告时区当天结束换算，不将截止时间显示为确定的重置时刻。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.43)；注释标签指向源码提交 `8c414196923e4cb98eddb45417489932df562875`。功能提交为 `ffb8de7`。
- [main 双架构构建](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/38334907487)的来源检查、四个回归作业和两个打包作业全部成功。[标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/38336763927)成功复用同一提交、同次运行和 attempt 1 的 Apple Silicon 与 Intel 产物。
- Release 于北京时间 2026-10-13 10:25:23 公开，非草稿、非预发布。Latest 与正文经独立核验；正文和标签提交中的 `RELEASE_NOTES.md` 完全一致。

## 修复与验证

- 按公告发布时间所在的来源时区确定 EOD 对应日期；PST 保持 UTC−8，PDT 保持 UTC−7，PT 根据来源日期采用夏令时。日末边界使用日历计算，覆盖 23 小时和 25 小时的夏令时切换日。
- 保留明确的相对日期和绝对日期；缺少可靠时区或相对日期缺少发布时间时，不猜测本地截止时间。到期仅退出预告展示，不标记为已完成重置，也不推断当前账号额度恢复。
- 本地 `bash scripts/test-hooks.sh --filter ResetNewsCoreTests` 通过 131 项测试；`scripts/test-reset-news-date-card.sh` 通过 61 项原生检查。已检查 340 点宽度下的浅色、深色 EOD 卡片，日期、截止措辞和换算依据显示完整。
- 双架构完整回归均通过上述 CI。本版只提交 EOD 修复、对应测试及版本说明；工作区中其他未提交改动未纳入发布源码。

## 公开产物核验

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `81aef37c174763c6cbdd10fcd2a0437e5c6d55d79a75e1d06c0b1e46e0799508` |
| `GPT-TouchBar-HUD-0.1.43-arm64.dmg` | 4,742,334 | `9975272eacfb950974fa2df0fa0e39279f98a247ac7f6b8e7aa8625007936981` |
| `GPT-TouchBar-HUD-0.1.43-x86_64.dmg` | 4,940,033 | `0b910afc3cfbf6aceb22627a664e038a45134c00889d380159e0bfdd73400907` |
| `SHA256SUMS.txt` | 201 | `2a92b83fd4aabf811cee2119278a7f01c85d62a5acd1f06364c9699d89428365` |

使用 `python3 -B scripts/verify-public-release.py v0.1.43` 从公开 Release 重新下载四份附件，核对 GitHub 摘要、大小、合并校验文件和构建清单。源码及同次构建来源、版本 0.1.43 / Build 46、应用标识、主程序与 helper 架构、macOS 11.0 最低系统标记、DMG 完整性、只读挂载、严格签名及首次打开助手 CDHash 绑定全部通过；挂载卷已卸载。下载使用系统已配置的本地代理，未修改系统代理设置。

[机器可读核验清单](validation/release-0.1.43-publication.json)保存公开附件与 CI 来源。下载文件及核验原始结果保存在本地 `build/release-evidence/public-v0.1.43/`，CI 状态保存在 `build/release-evidence/v0.1.43/`。本记录在标签发布后提交，不改变发布二进制的源码来源。

## 验证范围

真实 macOS 11、实体 Touch Bar / 刘海、正式安装路径的升级重启尚未实机验收。安装包为 ad-hoc 签名，未经 Apple 公证；本次未替换或启动本机已安装应用。
