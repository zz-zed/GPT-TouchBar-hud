# v0.1.45 发布记录

2026-10-16。**GPT TouchBar HUD v0.1.45 / Build 48 已正式发布并设为 Latest。**

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.45)于北京时间 2026-10-16 14:54:15 公开，非草稿、非预发布；附注标签指向源码提交 `f5f4493ce464545ab3505cbb41b343903d0b378b`。
- [main 完整双架构 CI](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/38861944747)的来源检查、四个回归作业、两个打包作业及 CI Gate 全部成功。两架构安装包均来自 run `38861944747`、attempt `1`。
- [标签发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/38863817745)复用上述原始产物，未重新编译。公开正文与标签提交中的 `RELEASE_NOTES.md` 完全一致。

## 本版变更

- 调整菜单栏摘要和预告日期布局，统一菜单栏、Touch Bar、刘海 HUD 的展示快照、语言、日期与时区。
- 从 AppDelegate 拆分显示、设置和生命周期协调；保留宿主与 Codex 门禁、叠加暂停、安装期间拒绝退出、三秒退出期限及一次完成保护。退出期间关闭界面入口，迟到回调不能重启服务或重新打开设置。
- 修复迟到焦点通知关闭新一轮预告弹窗的问题；真实失活、前台进程切换与正常关闭路径继续有效。
- 修复复合时长被截断、导致预告提前过期的问题；支持明确的小时加分钟。对已识别但未支持的紧邻时长续段保留未知时间，包括 half、plus、英文复合数词和约数等测试场景；不将此解析器视为任意自然语言解析器。
- 修复没有额度窗口时账号刷新失败提示与重试入口丢失的问题，覆盖仅重置次数、空窗口和状态恢复。

## 验证

本地回归覆盖 Core 267 项、菜单 388 项、原生日期卡片 87 项；菜单包括中英文失败行几何、可读性、重试回调和恢复状态。两轮时长补充均先在旧生产代码上复现失败，再验证修复。独立代码复核未发现剩余 P1/P2。

远端对最终源码完成双架构完整回归及打包。发布前的一次旧源码构建因补齐同类时长边界而主动取消，未用于本次发布；最终来源以上述成功运行和 attempt 为准。

公开后运行 `python3 -B scripts/verify-public-release.py v0.1.45 --repo zz-zed/GPT-TouchBar-hud` 重新下载四份附件。Latest、正文、标签、清单、来源 SHA、同次 CI、附件大小与 SHA-256、DMG 完整性、只读挂载、版本 0.1.45 / Build 48、App/Helper 架构、macOS 11.0 最低标记、严格签名及首次打开助手 CDHash 绑定均通过。挂载卷已卸载。

首轮直连附件下载超时；随后仅在验证命令中使用系统已有本地代理完成下载与核验，未修改系统代理配置。原始尝试和最终日志保留在本地。

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `e2becf2bf11102d20c5687fccad9a34b7c3c2d915c37d8d704e2f28a7f66f5d7` |
| `GPT-TouchBar-HUD-0.1.45-arm64.dmg` | 4,917,323 | `96f69abd88f3bca86c160f9f70eac76b4fa7c34fa04e458423bdc9f8c613b473` |
| `GPT-TouchBar-HUD-0.1.45-x86_64.dmg` | 5,119,327 | `40c5303c0d15873654b1536431d4fb92222da7f95a8fcc502782ff7e9b397c85` |
| `SHA256SUMS.txt` | 201 | `94c8d61243fb85632eb3fa6d908b04b40bc0fa3c7146a91c5874ff9a3a0fcc89` |

[机器可读核验清单](validation/release-0.1.45-publication.json)保存公开附件与 CI 来源。公开下载及本轮 CI 记录保留在本地 `build/release-evidence/public-v0.1.45/` 和 `build/release-evidence/v0.1.45/`；旧本地验证、设计及恢复材料按清理清单留存于 `backups/release-0.1.45-cleanup-20261016.noindex/`。本记录在标签发布后提交，不改变二进制来源。

## 验证边界

弹窗焦点回归使用受控焦点事实和真实 NSPopover/NSWindow 生命周期；历史外屏偶发问题是否均由同一原因造成尚未证明，外屏重开仍待实机复测。部分 SwiftUI 辅助功能节点未在本地原生树中暴露，不能声明已全部验收。

实体 Touch Bar、刘海硬件及实际 macOS 11 运行未完成验收。双架构 CI 和最低系统标记不替代实机兼容性验证。安装包使用 ad-hoc 签名，未经 Apple 公证；本次只读验包没有替换或启动本机正式应用。
