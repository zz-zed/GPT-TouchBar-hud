# 测试覆盖

日常入口为 `make check`，测试部分调用 `bash scripts/test-core.sh`。完整核心检查在 ARM 上运行；发布时 Intel 运行 `bash scripts/test-core.sh --smoke` 并验证该架构的安装包。`--smoke` 在生产 App 构建后执行，默认读取 `build/GPT TouchBar HUD.app`，也接受 `HUD_APP_DIR`。

完整专项入口为 `make full`，实际 DMG 验包入口为 `make verify`。独立测试脚本可以按修改范围单独运行。

## 核心检查

1. 检查更新身份、版本和资产命名契约。
2. 执行 HookCore、ResetNewsCore 的 SwiftPM 测试。
3. `core-test-build.sh` 将 `Sources/*.swift`（排除 `main.swift`）编译成启用 `-enable-testing` 的 `HUDCoreTestSupport` 静态模块。
4. 应用层 fixture 分别链接并在独立进程执行，不共享可变全局状态。当前清单包括任务、Token、账号、额度提醒、API 消费及界面、自动启动、宿主生命周期、更新和迁移。
5. 检查安装脚本的文件状态与回滚、Notch 模型与合成几何，以及真实进程的单实例锁。

每个 fixture 有外部进程超时；超时和取消只终止该次检查创建的进程组，失败保留非零退出码。测试库与生产应用使用不同编译参数，不能将测试产物用于发布。

## 覆盖矩阵

| 独立入口 | 执行范围 | 主要覆盖与边界 |
| --- | --- | --- |
| `test-hooks.sh` | 核心 | HookCore/ResetNewsCore 的配置合并、清理、回滚、权限、IPC、任务引擎、重置时间与通知语义。 |
| `test-task-status.sh` | 核心 `TaskStatusTests` | 任务展示、故障降级、完成反馈及隔离日志；核心不运行 `--live-smoke`。 |
| `test-token-usage.sh` | 核心 `TokenUsageScannerTests` | 时间区间、增量读取、截断、替换、无效行与重复计数。 |
| `test-account-token-usage.sh` | 核心 `AccountTokenUsageTests` | 宿主发现、账号切换、异步回调与用量；不访问真实账号。 |
| `test-api-costs.sh` | 核心 `APICostTests`、`APICostUITests` | API 消费服务与设置界面；使用合成响应、内存凭据替身和隔离偏好，不读取真实密钥。 |
| `test-verified-quota.sh` | 核心 `VerifiedQuotaTests` | 账户归属、混合账户拒绝、连接失败、异步请求与重试。 |
| `test-quota-alerts.sh` | 核心 `QuotaAlertTests` | 固定时钟阈值、静默基线、通知去重、权限与账户隔离。 |
| `test-host-auto-launcher.sh` | 核心 `HostAutoLauncherTests` | 模拟 launchctl、临时文件、退出与停用偏好、命令超时和 shell 行为；不注册真实启动项。 |
| `test-host-lifecycle.sh`、`test-app-lifecycle-state.sh` | 核心 | 宿主/Codex 独立状态、重复事件、重叠暂停、迟到回调与显式重启。 |
| `test-app-update.sh` | 核心与专项 | 核心覆盖版本、资产信任、摘要、调度、通知、文件替换和回滚；真实 AppKit 退出单独验证。 |
| `test-github-release-fallback.sh` | 核心 | API/页面回退、重试与资产信任故障注入；核心不运行联网的 `--live-evidence`。 |
| `test-app-update-notifications.sh` | 核心 | 提醒去重、版本变化、权限和偏好；使用假通知通道。 |
| `test-app-migration.sh` | 核心 | 隔离 defaults 中的旧偏好迁移，保留当前选择与未知键。 |
| `test-notch-presentation.sh` | 核心模型与交互专项 | 核心使用合成屏幕几何、假时钟和内容断言；真实窗口、截图、鼠标穿透及事件循环由专项验证。 |
| `test-single-instance.sh` | 核心与 native smoke | 进程争抢、正常退出与崩溃恢复、子进程锁继承、文件错误和符号链接拒绝。 |
| `test-hook-helper.py` | 性能专项；native smoke 覆盖短功能集 | smoke 使用已构建 Helper，检查真实启动、无监听器、非法或超限输入、IPC 最小化和有界退出；重复采样与严格延迟检查单独运行。 |
| `test-hook-integration.sh`、`test-task-reliability.sh` | Hooks/任务专项 | 多组件接线、任务规模、恢复与模式切换；核心模块测试不能替代端到端覆盖。 |
| `test-connection-diagnostics.sh`、`test-diagnostic-logging.sh`、`test-diagnostic-upgrade-*.sh` | 诊断专项 | 报告、导出、持久化、隐私、并发及升级接续。 |
| `test-app-update-progress.sh`、`test-app-termination.sh`、`test-app-lifecycle-termination.sh` | 更新/生命周期专项 | 下载、进度 UI、真实 AppKit `terminateLater`、等待写入与退出回执。 |
| `test-reset-news-runtime.sh` | 预告运行时专项 | 存储与通知接线；规则及时间语义另由核心模块测试覆盖。 |
| `test-hud-material.sh`、`test-idle-performance.sh`、`test-status-menu.sh`、`test-notch-hud.sh`、`test-touchbar.sh`、`test-touchbar-layout.sh`、`test-design-layout.sh` | 界面与性能专项 | AppKit/SwiftUI 视图、布局、菜单、材质与性能；需要相应图形环境或硬件。 |
| DMG、首次打开助手、早期更新协议、历史安装/回滚 | 发布双架构 `make verify` | 验证实际新包；安装夹具不代表完整应用已经在所有目标系统启动成功。 |

调整测试执行位置时，应同步维护覆盖关系和限制。核心检查通过不代表完整交互或实体设备测试已经完成。

## 本地选择

```sh
make check                     # 生产构建和核心检查
make package                   # 构建 DMG
make verify                    # 验证已有包与升级兼容
make full                      # 完整专项，包含图形环境检查
bash scripts/test-core.sh --list
```

`--list` 仅输出核心执行清单，不需要 Swift/macOS 安装，也不会运行测试。Linux 上的语法或静态检查不能替代 macOS 原生编译、DMG 验包及设备交互验证。
