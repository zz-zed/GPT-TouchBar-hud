> 历史记录：Build 31 已由 [Build 32](RELEASE-PREPARATION-0.1.29.md) 取代；原 App 和 DMG 保留在主目录 `backups/notch-polish-build31/`。

# 0.1.29 发布准备：Build 31

2026-09-21。本地 `main` 已整合本轮必要代码与文件，完成 **0.1.29 / Build 31** 的 arm64 候选构建、回归和打包校验，并清理全部 5 个附加 worktree。本轮没有推送、创建标签或公开 Release，也没有安装、替换或启动正式 App。只读检查时，远端 main 为 `3007f8a`，公开最新版为 `v0.1.28`。

## 主分支与版本范围

- 主目录：`/Users/didi/Desktop/codex-space/TouchBarCodexToken`，保留分支 `main`。
- 合并前 main：`3007f8ae73daec9fcc2e15628a99bd18753eaffb`。
- 功能汇集提交：`f49533c3b472520ab8644f03c27892325ec35f80`，通过 fast-forward 合入 main。
- 本次实际构建输入：`1ebd440083856fabe9a888e13fe0ab9f471ef716`；后续提交仅记录验证与清理结果。
- 新候选保持未发布的 0.1.29，Build 从 30 增至 31，以区分新增原生刘海三态及启动自动适配后的包。

本版包含原生刘海 Compact / Peek / Expanded、额度/活动/用量分页、始终显示额度设置、动画期间的实际轮廓点击判断，以及自动检查更新。启动时，未保存模式的用户使用自动检测；有刘海且未保存显示状态时直接显示面板。已保存的手动模式和隐藏设置优先，重新选择“自动”可恢复适配。旧版本无法区分手动选择与随可见性保存的模式值，因此所有既有合法模式均予以保留。

`3ab2` 的两项刘海改动和 `436e` 的自动更新改动，经 `git cherry` 确认均有补丁等价提交在整合历史内。没有遗漏独有补丁，也没有再次覆盖已经整合的实现。README、发布说明及贡献检查项已同步当前行为；旧渲染器和独立原生调试入口仍保留。

## 本次验证

以下均在主目录、Build 31 构建输入上执行，没有使用 Build 30 的结果替代本次检查。

| 检查 | 结果 |
| --- | --- |
| 旧设置迁移 | 4 项通过 |
| 账号 Token / 本地 Token 计数 | 53 / 18 项通过；未运行真实账号 smoke |
| Touch Bar 布局 / 生命周期 | 291 / 34 项通过；未运行系统级 smoke |
| 任务状态 | 41 项通过 |
| 更新策略和安装脚本边界 | 73 项及脚本语法、非法目标拒绝通过 |
| 刘海几何、偏好、菜单与集成 | 202,778 项通过，含大量几何采样，并非同数量用户场景 |
| 设计集成 | 158 项通过 |
| 原生刘海呈现 | 本轮一次通过 356 项，采集 306 个实际动画几何样本；真实 WindowServer 鼠标事件投递及焦点检查通过 |
| HookCore | `scripts/test-hooks.sh`：7 组、41 项通过 |
| 分发构建 | arm64 优化编译、App 与 helper 严格签名校验通过 |
| 包版本与系统目标 | 源码/build/挂载 App plist 一致；0.1.29 / Build 31，最低声明和 Mach-O minos 均为 11.0 |
| DMG 校验 | `hdiutil verify`、SHA-256 校验及只读挂载通过；包内 8 个 App 文件与 build App 的哈希、大小完全一致 |
| 首次打开助手 | 绑定本包 CDHash、无模板占位符；隔离副本的取消、属性保留、重复执行、符号链接、哈希不符、异常参数、签名篡改回归通过 |
| 文档 | 发布相关本地链接与 Git 空白检查通过 |

原始日志位于 `build/release-evidence/build31/`。可提交的证据为 [测试摘要](validation/release-0.1.29-build31-tests.txt) 和 [候选清单](validation/release-0.1.29-build31-artifact-manifest.json)。此前启动策略迭代发生过一次焦点断言失败、原样复跑通过，保留在 [刘海验证记录](NotchIsland/VALIDATION.md)；本次主目录候选回归未复现该失败。

## 当前候选

- App：`build/GPT TouchBar HUD.app`
- arm64 DMG：`dist/GPT-TouchBar-HUD-0.1.29-arm64.dmg`
- 本地 SHA-256 清单：`dist/SHA256SUMS.txt`，仅包含本次 arm64 候选。
- DMG 大小：`3100387` 字节。
- DMG SHA-256：`65b93b5a8e0f3ee598dcdf7bde4af1a09c85a98997ab761610f659d4096a6721`。
- App CDHash：`b9b61770d6e5c6b585687c0a1ddbb3bf648cd457`。

以上路径均相对于主目录。本次包包含最新实现，替代先前仅含旧刘海外壳的 Build 30；Build 30 的 [准备记录](RELEASE-PREPARATION-0.1.29-build30.md) 与 [清单](validation/release-0.1.29-build30-artifact-manifest.json) 作为历史证据保留。

## Worktree 清理与保留文件

清理前核对了正常/忽略文件、各提交与 main 的包含或补丁等价关系、运行中程序、LaunchAgent 和实际安装路径。LaunchAgent 指向 `/Applications/GPT TouchBar HUD.app`；没有正在使用待清理目录的 App 或测试可执行文件。通用 CUA/node 工具进程虽持有其中两个目录的工作路径，但没有作为仓库程序运行，本轮未终止这些宿主工具进程。

5 个附加 worktree 使用不带 `--force` 的 `git worktree remove` 删除；已合并的旧 `release/0.1.29` 分支也已删除。清理后 Git 仅登记主目录的 main。

本地保留目录：`backups/worktree-cleanup-20260921-112910/`。归档前后校验了 593 个文件/符号链接条目，并以通过验证的 Git bundle 保留原始提交，包括两条补丁等价的 detached 开发线。仅编译及模块缓存作为可重建内容随工作树移除；设计稿、截图、验证日志、旧 App、旧 DMG 和上游参考资料均予以保留。

| 原 worktree | 原提交 | 本地归档子目录 |
| --- | --- | --- |
| `3ab2` | `02f76de` | `3ab2/` |
| `436e` | `b3297e4` | `436e/` |
| `notch-update-integration` | `b5a5bbe` | `notch-update-integration/` |
| `release-0-1-29-prep` | `a2969a0` | `release-0-1-29-prep/` |
| `cf09` | `f49533c` | `cf09/` |

主目录原有 Design/build/dist 也在 `main-before-preparation/` 中留有快照。归档 `inventory.json` 提供每个原路径、保存位置和 SHA-256；[清理清单](validation/worktree-cleanup-2026-09-21.json) 记录实际移除结果。历史文档中的旧 worktree 路径不再是当前交付位置。

## 正式发布前的剩余边界

- 本地只生成 arm64；Intel 的构建、签名和运行仍需要远端 Intel runner 验证。
- macOS 11 仅验证编译/链接目标；实体刘海黑位、接缝、菜单栏拥挤、缩放、全屏、热插拔和唤醒尚未实机验收。
- 正式安装路径下的定时更新、真实网络/限流和安装重启链路未端到端验收；Hook 真实启用与任务准确性没有新增结论。
- 当前为 ad-hoc 签名，未做 Apple Developer 签名或公证。
- `.github/workflows/build-dmg.yml` 会在推送 `v*` 标签后自动公开 Release。本轮仅准备本地 main 和候选；远端 main、双架构 CI、标签与公开发布均待后续正式发布操作。
