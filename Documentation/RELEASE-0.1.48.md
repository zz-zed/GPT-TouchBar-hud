# v0.1.48 发布记录

2026-10-26。GPT HUD v0.1.48 / Build 51 已于北京时间 18:36:28 正式公开并设为 Latest，非草稿、非预发布。

- [正式 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.48)的附注标签固定指向源码 `a4f8da3320f639033c73b32d790a811c6936ba0a`。
- [main 完整 CI](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/40305486108)的来源校验、四组回归、两份 DMG 与 CI Gate 共八个唯一作业全部成功。双架构资产均来自该 run、attempt 1，任务时间及产物来源已核对。
- [正式发布工作流](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/40308653690)复用上述原始资产，验证与公开两个作业均成功，没有重新编译。公开正文与标签提交的 `RELEASE_NOTES.md` 一致。

## 本版内容与验证

状态菜单采用紧凑布局，保留任务状态，将可用重置与公开预告并排展示，并突出日期和时间。刷新图文间距收紧，HUD 与更新使用直接原生动作，真正包含多个选项的偏好菜单保持子菜单。Token 提示在最终布局后注册范围，并在回调时检查当前指针所在的字段边界和可见区域。

本地日期专项测试 106 项通过，覆盖精确时刻、截止时间、日期未知时刻、跨年及 DST。最终菜单测试本地连续三个独立进程均通过 863 项检查；ARM 与 Intel CI 也分别通过 863 项，四个中文/英文 HUD 与更新 Return 动作均在真实 NSMenu tracking 中验证选中项及唯一回调。布局、截图和 tooltip 坐标检查在隔离 NSWindow 中承载真实摘要视图与合成动作区域，未在 tracking 回调中绘图或移动字段。

初次 run `40299126034` 的状态菜单测试编译成功后长时间未退出，取消后 CI Gate 失败。加入独立超时后，run `40303632350` 在两架构均明确停于第二次深色快照 tracking，并以 60 秒超时、退出码 124 失败。最终将绘图与 tooltip 几何测试移出 tracking，每个键盘用例创建独立菜单，保留原有断言和超时保护；完整新源码 CI 成功后才创建发布标签。前两次运行的资产没有用于发布。这些记录说明测试停点与修复范围，不将 AppKit 内部行为推断为已证实根因。

## 公开验包

运行 `python3 -B scripts/verify-public-release.py v0.1.48 --repo zz-zed/GPT-TouchBar-hud`，重新下载四份公开附件。Latest 状态、正文、附注标签源码、同次构建清单、大小与 GitHub digest/SHA-256、DMG 完整性、只读挂载、版本 0.1.48 / Build 51、App/Helper 架构、最低 macOS 11.0 标记、严格签名与首次打开助手 CDHash 绑定均通过。

| 附件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `build-manifest.json` | 4,010 | `77be647f00384987454d5a2d476660b39c78616529b4c75738cc685861c8a504` |
| `GPT-TouchBar-HUD-0.1.48-arm64.dmg` | 4,974,902 | `3e8306eb4609ee90854cab6a480bc40293659af123075ef7900a7e1eb04800b0` |
| `GPT-TouchBar-HUD-0.1.48-x86_64.dmg` | 5,161,105 | `b91e24071842e77b31821bcb8df38b279eac08eb2305d6cce8e628c78fe6d5af` |
| `SHA256SUMS.txt` | 201 | `e731eb7c9861ca1ffc67746ff67e52d4616483d1fa60317b86b18a56aeb77d41` |

[机器可读证据](validation/release-0.1.48-publication.json)保存上述结果及 CI 门禁绑定。本地公开下载与原始核验报告位于 `build/release-evidence/public-v0.1.48/`。本记录在标签之后提交，不改变二进制来源。

## 验证边界

物理鼠标 hover 会话、人工 VoiceOver、实际 macOS 11、实体 Touch Bar/刘海与真实安装升级未在发布任务中验证。自动 tooltip 坐标检查不代表已人工复现或确认用户 hover 问题的根因。安装包使用 ad-hoc 签名，未经 Apple 公证；应用文件名与数据路径没有自动迁移。

本次发布任务没有安装、替换或启动用户已安装的应用。本地既有安装记录、备份和原始验证材料保持原样，未加入公开提交。
