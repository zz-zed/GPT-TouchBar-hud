# 任务状态 Hooks 接入原型

这是隔离的可行性验证，不是已上线的任务状态实现。不会被 Swift Package 编译或 DMG 打包；脚本不会自动修改当前 HUD、用户配置、Hook 信任记录，也不会启动模型任务。原型使用 Node.js 内置模块；这不意味着正式应用将新增 Node.js 依赖。

## 实验语义

Hooks 通知只能提供候选任务线索，不能单独证明完整的运行任务数量。提交提示后，其他 Hook 可能阻止执行；收到 Stop 后也可能续跑。中途接入、宿主崩溃和上报丢失需要额外校准来源。

原型输出 `submittedCandidates`，将 `authoritativeRunningCount` 保持为 `null`；候选数不能直接作为正式 UI 的权威运行数量。

## 结构与边界

`Hook → 有时限的本地发送器 → Unix socket 接收器 → 元数据快照`

- `bridge.mjs`：事件白名单、接收器、状态归并，以及打印待审阅 Hook 配置的命令。
- `recovery.mjs`：启动时按缓存会话定位日志，使用精确轮次的终态记录修复旧缓存。
- `probe-runtime.mjs`：只在独立运行时实例上验证配置发现能力；不创建/恢复任务，不发起模型请求，不写入信任设置。
- `tests.mjs`：状态归并和真实本地 socket 的合成事件测试。

不设置轮询定时器，不持续扫描会话日志；启动恢复仅检查缓存任务的有界日志尾部。快照只记录会话 ID、轮次 ID、事件对应的观测状态、本地接收时间和恢复计数，并保留最多 128 条已更新状态的事件元数据；不保存提示词、助手回复、工作目录、工具参数或 transcript 路径。恢复不会伪造新的 Hook 事件；重复且被去重的提交不会产生新的状态更新记录，事件记录不是无损全量审计日志。

事件归并原则：

| 事件/情况 | 原型行为 |
| --- | --- |
| `UserPromptSubmit` | 增加候选会话，同一会话不因重复事件或多轮次重复计数 |
| `Stop` | 记为“观察到停止”，不等同成功完成 |
| `Interrupt` | 记录该轮次中断，旧轮次事件不取消新轮次 |
| `SessionEnd` | 未结束任务标未知，保留终态及停止观测，不推定任务成功完成 |
| 长时间无事件 | 不靠超时制造完成或空闲结论 |
| 接收器重启 | 保留终态，未结束任务降为未知，按精确轮次做一次有界终态校准；覆盖范围仍不完整 |
| 超过 512 条记录 | 淘汰旧记录并提示容量缺口；不能当作完整总数 |

不监听 `SubagentStart` / `SubagentStop`，但主任务/子代理的实际事件身份和覆盖范围仍须真实宿主联调验证。Hook 没有可靠的全局事件序列号，原型仅处理部分重复和乱序，不宣称能够完全恢复事件顺序。

接收目录要求当前用户拥有且权限为 `0700`，socket 和快照为 `0600`。拒绝复用已有 socket，避免删除另一个接收器的入口。IPC 不是对同用户恶意进程的认证边界，不应把输入视为可用于安全决策的可信信息。

发送器对输入设置 1 MiB 上限，连接/确认等待上限为 200 ms，脚本内整体处理期限为 500 ms；生成的 Hook 配置超时为 1 秒。超限、格式错误、接收器不存在或无响应时均返回中性的 `{}` 和退出码 0，不阻止任务，不添加提示词，不修改授权结果。时限不包括操作系统启动进程前的调度延迟。

上报失败时采取放行任务的策略，因此事件可能丢失。接收器无法单靠沉默发现宿主崩溃或所有上报丢失；这也是不能报告权威数量的原因。正式接入需要宿主运行状态/快照校准，而不只是延长过期时间。

## 复现本地检查

在仓库根目录执行，需要 Node.js 22 或兼容版本：

```bash
node --test experiments/task-status-hooks/tests.mjs
node experiments/task-status-hooks/probe-runtime.mjs
bash scripts/test-task-status.sh
```

自行启用项目配置后，可用下列只读命令检查配置发现及信任状态：

```bash
node experiments/task-status-hooks/probe-runtime.mjs --project
```

可传入其他安装位置的 Codex 可执行文件：

```bash
node experiments/task-status-hooks/probe-runtime.mjs /absolute/path/to/codex
```

接收器需单独运行在私有临时目录中：

```bash
probe_dir=$(mktemp -d /tmp/hud-hook-probe.XXXXXX)
node experiments/task-status-hooks/bridge.mjs receive "$probe_dir/events.sock"
```

接收器会打印 socket 和快照路径。另一个终端可以用实际 socket 路径生成供审阅的配置，下面命令只打印、不安装：

```bash
node experiments/task-status-hooks/bridge.mjs config /tmp/hud-hook-probe.EXAMPLE/events.sock
```

生成配置包含当前 Node 和脚本的绝对路径，只适用于本机试验。不要将个人路径作为公共默认配置提交；不要直接覆盖已有 `hooks.json`。启用前应合并并检查已有定义，在宿主提供的 Hook 界面审阅并信任。不得使用跳过信任检查的参数。

## 验证边界

旧会话热加载、任务中途接入、多个任务来源、中断、接收器重启、宿主异常退出与休眠恢复均需独立验证。缺少覆盖证据时维持候选或未知语义。临时接收器不会安装登录项。

## 官方依据

- [Hooks](https://learn.chatgpt.com/docs/hooks)：事件、信任流程、输出契约、Stop 续跑语义。
- [App Server](https://learn.chatgpt.com/docs/app-server)：`hooks/list`、运行状态事件和已加载任务接口。独立实例不代表桌面宿主的内存状态。
