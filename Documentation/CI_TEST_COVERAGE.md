# 核心检查与旧断言迁移

日常入口是 `make check`，测试部分调用 `bash scripts/test-core.sh`。完整核心检查在 ARM 上运行；发布时 Intel 运行 `bash scripts/test-core.sh --smoke` 并验证该架构的真实安装包。`--smoke` 必须在生产 App 构建后执行，默认读取 `build/GPT TouchBar HUD.app`，也接受 `HUD_APP_DIR`。

本次收敛改变执行频率与编译方式，不以删除旧断言换取绿色结果。原独立测试脚本继续可单独运行；完整专项入口为 `make full`，实际 DMG 验包入口为 `make verify`。日常检查和发布的耗时目标需要用真实 macOS 运行测量，不包含 GitHub runner 排队。

## 核心检查如何复用编译

1. 先运行轻量更新身份/命名合同检查。
2. 执行原有 HookCore、ResetNewsCore 全部 SwiftPM 测试。只运行这两组并不足以覆盖产品，因此还保留下面的应用层 fixture。
3. `core-test-build.sh` 将 `Sources/*.swift`（排除程序入口 `main.swift`）编译成一个仅供本次检查使用的 `HUDCoreTestSupport` 静态模块。采用与已有 UI 测试共享模块相同的 `-enable-testing` 和 force-load 链接方式；不会替换生产 App 构建。
4. 十二个现有业务 fixture 分别链接并在独立进程中执行，保留原正文与断言，只增加条件 `@testable import`。同一 fixture 不再重新编译整套应用源码，fixture 之间也不共享可变全局状态。
5. 直接执行原 `NotchModelChecks` 的模型、几何、内容断言。共享 fixture 数据从原 GUI harness 提取，原 GUI harness 继续使用相同数据；核心入口不创建 NSApplication、不弹菜单、不启动窗口或真实宿主。

测试库每次入口重新构建，不增加跨运行二进制缓存或来源证明协议。每个业务 fixture 有外部进程超时；超时和取消只终止该次测试创建的进程组，失败保持非零退出码。macOS 原生编译与运行结果才是最终验证，Linux 上的脚本语法检查不能替代它。

## 迁移矩阵

| 原覆盖/入口 | 新执行位置 | 保留的内容与边界 |
| --- | --- | --- |
| `test-hooks.sh` | 核心必跑 | HookCore/ResetNewsCore 全部现有测试，包括配置合并/清理/回滚、路径与权限拒绝、IPC、任务引擎、重置时间与通知语义。 |
| `test-task-status.sh` | 核心 `TaskStatusTests` | 原任务展示、故障降级、完成反馈及隔离任务日志断言；不传 `--live-smoke`。 |
| `test-token-usage.sh` | 核心 `TokenUsageScannerTests` | 原时间区间、增量读取、截断、替换、无效行与重复计数断言。 |
| `test-account-token-usage.sh` | 核心 `AccountTokenUsageTests` | 原宿主发现、账号切换、异步回调与用量断言；不访问真实账号。 |
| `test-verified-quota.sh` | 核心 `VerifiedQuotaTests` | 原账户归属、混合账户拒绝、连接失败、异步请求与重试断言。 |
| `test-quota-alerts.sh` | 核心 `QuotaAlertTests` | 原固定时钟阈值、静默基线、通知去重、权限与账户隔离断言。 |
| `test-host-auto-launcher.sh` | 核心 `HostAutoLauncherTests` | 原模拟 launchctl、临时文件、用户退出/停用偏好、命令超时与 shell 行为断言；不会注册真实启动项。 |
| `test-host-lifecycle.sh`、`test-app-lifecycle-state.sh` | 核心两个原 fixture | 宿主/Codex 独立状态、重复事件、锁屏/睡眠重叠、停止与迟到回调、显式重启。 |
| `test-app-update.sh` | 模型与 shell 状态机进核心；真实 AppKit 退出进完整专项 | 原 `AppUpdateTests` 全部版本、资产信任、摘要解析、调度与通知决策断言；原 `AppUpdateInstallerTests.zsh` 全部临时文件替换、失败回滚、重复执行与边界拒绝；保留 shell 语法和非法目标拒绝。 |
| `test-github-release-fallback.sh` | 核心原 fixture | API/页面回退、错误/重试与资产信任故障注入；不传联网的 `--live-evidence`。 |
| `test-app-update-notifications.sh` | 核心原 fixture | 原提醒去重、版本变化、权限和偏好断言；使用假通知通道。 |
| `test-app-migration.sh` | 核心原 fixture | 隔离 defaults 中的旧偏好迁移，保留当前选择与未知键边界。 |
| `test-notch-presentation.sh` | 原纯模型部分进核心；原交互部分进完整专项 | 原 `NotchModelChecks` 全部模型、合成屏幕几何、内容与假时钟动画/空闲断言；真实窗口、截图、鼠标穿透和事件循环不进入日常。 |
| `test-single-instance.sh` | 核心与 native smoke | 继续运行原真实进程争抢、正常退出/崩溃恢复、存活子进程不继承锁、文件错误与符号链接拒绝；仅编译小型 probe。 |
| `test-hook-helper.py` | 完整性能专项；native smoke 覆盖短功能集 | smoke 消费已构建的 Helper，检查真实启动、缺失监听器、无效/超大/不完整输入、Unix socket 数据最小化及无确认时有界退出。原 20 次采样及严格延迟阈值仍可手动运行。 |
| `test-hook-integration.sh`、`test-task-reliability.sh` | 完整专项；Hooks/任务引擎相关变更时运行 | 原多组件接线、任务规模、恢复与模式切换的集成断言不删除。核心中的模块测试与原任务显示 fixture 不声称替代这些端到端覆盖。 |
| `test-connection-diagnostics.sh`、`test-diagnostic-logging.sh`、三个 `test-diagnostic-upgrade-*.sh` | 完整专项；诊断相关变更时运行 | 原报告、导出、持久化、隐私、并发及升级诊断证据断言保留。 |
| `test-app-update-progress.sh`、`test-app-termination.sh`、`test-app-lifecycle-termination.sh` | 完整专项；更新/生命周期相关变更时运行 | 原下载服务、进度 UI、真实 AppKit terminateLater、等待写入与退出回执断言保留。核心状态机不等于真实 GUI/进程交接成功。 |
| `test-reset-news-runtime.sh` | 完整专项；预告运行时相关变更时运行 | 模块中的全部规则/时钟断言每天保留，原实际运行时与存储/通知接线继续专项覆盖。 |
| `test-hud-material.sh`、`test-idle-performance.sh`、`test-status-menu.sh`、`test-notch-hud.sh`、`test-touchbar.sh`、`test-touchbar-layout.sh`、`test-design-layout.sh` | 完整专项；对应交互变化时运行 | 保留原 AppKit/SwiftUI 视图、布局、原生菜单、材质和性能断言。真实 `NSMenu.popUp` / `NSApp.run` 不进入核心入口。 |
| DMG、首次打开助手、最早更新协议、代表旧版安装/回滚 | 发布两架构 `make verify` | 检查真实新包。首次打开助手测试与历史安装夹具不等于当前完整应用实际启动验收，真机启动仍需单独确认。 |
| CI 分组实验、细粒度计时、框架清理自测 | 修改相应工具时或手动运行 | 不再作为每次应用代码变化的默认业务门禁。 |

所有原有独立 fixture 和完整脚本仍在仓库中。以后迁移或删除断言时，需在此表记录新归属及丢失的验证边界，不能因为新快测通过便认定某个完整交互测试已被替代。

## 本地选择

```sh
make check                     # 日常生产构建和核心快测
make package                   # 构建可交付 DMG
make verify                    # 验证已构建包与升级兼容
make full                      # 按需完整专项；包含真实 GUI
```

调查具体功能时仍可直接运行相应旧脚本。`bash scripts/test-core.sh --list` 仅输出核心选择清单，可在没有 macOS SDK 的环境审阅；它不会把“有文件”报告为“已通过测试”。
