# Hooks 接口与文件所有权

Hooks 通知用于加快本机任务的发现和核对，与普通日志模式共用连续读取器、任务库存和状态引擎。配置与能力边界见 [Hooks 实验说明](HOOKS-EXPERIMENT.md)。

## 消费端契约

`TaskActivitySnapshot: Equatable, Codable, Sendable` 是不可共享可变状态的值快照，包含：

- `confirmedRunningCount`、`pendingVerificationCount`、`submittedCount`、`recentlyCompletedCount`。
- `coverage`：覆盖范围与明确的缺口原因。
- `sourceHealth`：来源、连接状态与最近接收时间。
- `updatedAt`、`snapshotSequence`、`observationGeneration`。
- `recentCompletions`：用于反馈去重的完成身份与发生时间。

计数依据去重后的任务身份，不按 Hook 调用次数累计。待核对数可与运行数重叠；已提交属于待核对范围。`compactText` 提供紧凑的数量、待核对、未知和完成表达，完成状态仅在没有不确定项时成立。

覆盖范围与传输健康相互独立。生产初始化保留 `initialCoverageUnknown`，收到 Hook 不能消除全桌面任务覆盖缺口。连接正常不能被解释为任务范围完整或确认没有任何任务。

`HookConnectionController.onUpdate` 将 `TaskActivitySnapshot` 交给消费端，`onEngineSnapshot` 提供引擎快照。后台执行日志、SQLite 与 IPC 工作，界面更新回到主线程；停止、暂停和模式切换通过代次拒绝迟到回调。

应用只选择一种任务监测模式，不把普通日志与 Hooks 计数相加。Hooks 的显示适配器为 `HookCore/HookTaskDisplayAdapter.swift`，提供 `state`、`badge`、`label`、`detail`、`hasRunningTasks` 和 `snapshot`；完成反馈使用独立去重与显示时限。

## 模块职责

| 文件或模块 | 职责 |
| --- | --- |
| `HookCore/TaskActivitySnapshot.swift` | 消费端值类型、覆盖范围、健康状态与纯显示判断。 |
| `HookCore/TaskActivityEngine.swift` | 任务状态、读取预算、恢复、去重与统一快照。 |
| `HookCore/TaskJournalReader.swift` | 连续日志读取、文件身份与读取位置。 |
| `HookCore/TaskInventory.swift`、`TaskCheckpointStore.swift` | 分页发现和最小元数据断点。 |
| `HookCore/TaskEngineController.swift` | 后台调度、生命周期与回调代次。 |
| `HookCore/HookProtocol.swift`、`HookIPC.swift`、`HookPaths.swift` | 事件白名单、原生有界传输及私有存储路径。 |
| `HookCore/HookConnectionController.swift` | Hooks 模式下的引擎接入。 |
| `HookCore/HookConfiguration.swift` | 配置计划、备份、合并、读回校验与自有配置清理。 |
| `HookHelper/main.swift` | 原生事件发送助手，异常时不阻塞宿主任务。 |
| `Sources/HookExperimentPreferencesController.swift` | 默认关闭的设置入口，应用配置前提供审阅。 |
| `Package.swift`、`scripts/build-app.sh` | 模块与 helper 的打包、架构和嵌套签名。 |
| `Tests/HookCoreTests/` | 行为、安全边界、资源限制与隔离测试。 |

## 文件与配置边界

稳定 helper 位于 `~/Library/Application Support/GPTTouchBarHUD/Hooks/HookEmitter`，由签名 App 内的资源原子复制，保留前一版本以支持回滚。配置引用稳定安装位置，不使用构建目录中的临时可执行文件或符号链接。

IPC 与缓存使用 `~/.gpt-touchbar-hud-hooks`，避免超过 Unix socket 路径长度限制。目录权限为 `0700`，socket 和缓存权限为 `0600`。实际安装的 helper 必须通过签名和架构检查。

宿主自行管理 Hook 信任；配置变化后可能需要使用者审阅并重新发起任务。应用不能替宿主授予信任。测试通过显式配置路径与隔离偏好避免修改真实设置。

helper 只传递允许的生命周期字段，不转发提示词、回复、工具参数、工作目录或转录路径。关闭 Hooks 恢复普通日志模式；清理配置与 helper 属于独立操作，不能破坏其他工具的配置。
