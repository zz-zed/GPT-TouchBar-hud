# 任务状态诊断

当前任务监测机制与覆盖范围见[数据与隐私](DATA-AND-PRIVACY.md#任务状态的读取与判断边界)。应用内诊断与导出方式见[本机诊断与反馈](DIAGNOSTICS-M1.md)。

## 独立采集工具

`scripts/diagnose-task-status.command` 可单独运行，不需要整个仓库、Python、Xcode 或管理员权限。它使用基于 v0.1.40 的普通日志观察规则，适合辅助分析日志发现和事件读取；其候选上限与独立计数不代表当前 HUD 的任务库存、内存状态或界面结果。

[下载脚本](https://raw.githubusercontent.com/zz-zed/GPT-TouchBar-hud/refs/heads/main/scripts/diagnose-task-status.command) · [查看源码](../scripts/diagnose-task-status.command)

在终端下载到桌面后采集 2 分钟：

```bash
curl -fL --connect-timeout 15 --max-time 60 \
  'https://raw.githubusercontent.com/zz-zed/GPT-TouchBar-hud/refs/heads/main/scripts/diagnose-task-status.command' \
  -o "$HOME/Desktop/diagnose-task-status.command" && \
bash "$HOME/Desktop/diagnose-task-status.command" 120 fault
```

下载需要联网，采集过程不访问网络。命令会替换桌面上的同名脚本，下载失败不会执行；桌面的其他文件不受影响。

## 采集步骤

1. 保持 Codex 和 GPT HUD 运行，记录额度是否正常、任务区域是否显示数字，以及“显示任务状态（实验性）”的开关状态。
2. 开始采集后，发起一轮可观察的本地任务。采集期间保持任务开关和 Hooks 配置不变，避免多种变量同时变化。
3. 默认约 2 分钟后，桌面会生成 `TouchBar-task-diagnostics-日期-时间-编号.txt`。Control-C 可提前停止，已采集部分仍会保留。
4. 对照任务开始和结束时刻，核查报告与实际界面。分享前审阅报告，只提供定位问题需要的片段或结论，不提交原始会话日志、数据库、账号文件或完整导出包到源码仓库。

脚本支持 2–600 秒，例如 `bash 脚本路径 180`。较长采样有助于覆盖新任务的开始与结束，但不会扩大脚本的任务发现范围。

## 升级或重启后异常

若新发起的任务也不显示，可以用独立采集阶段比较，不要仅凭一次重启恢复推断根因：

1. 先保留异常现场，运行 `bash 脚本路径 120 fault`。
2. 保持 Codex 运行，只重启 HUD，再运行 `bash 脚本路径 120 after-hud-restart`。
3. 若仍异常，再重启 Codex，运行 `bash 脚本路径 120 after-codex-restart`。

阶段标记只写入报告，脚本不会自行重启应用。比较时区分 HUD 状态恢复、宿主日志恢复与宿主重启带动的 HUD 重建；任何一次恢复都不能单独证明原因。正常升级前也可运行 `bash 脚本路径 600 before-upgrade`，观察升级前后的进程变化。

## 采集范围与隐私

- 系统版本、进程架构、HUD / Codex 的 PID、启动时间及进程变化；应用版本与 Build 从 Info.plist 读取，不是读取进程内存中的常量。
- 已保存的任务、Hooks 和 Touch Bar 开关，不直接代表运行中实例的内存值。
- 默认 `.codex`、终端 `CODEX_HOME` 及 `launchctl getenv CODEX_HOME` 对应的候选目录。报告使用 H1 等匿名别名，不导出真实路径；没有读取 GUI 进程实际继承的环境。
- 只读查询 `state_5.sqlite`，按旧版筛选规则选择最多 32 个主会话，并提供最多 32 个最近未归档会话的匿名索引元数据。它不读取标题、提示词或账号信息，也不读取被排除会话的日志。
- 每文件每次最多读 256 KiB，建立基线后增量读取。报告记录有限生命周期事件、格式错误、读取失败、跳读和截断；文件使用匿名别名，不导出原始轮次 ID。

脚本不修改偏好、Hooks、宿主配置、数据库或日志，不调用额度接口，也不安装、启动或退出应用。只创建桌面报告和私有临时文件；临时文件在退出时清理。SQLite 子进程超时只终止该诊断进程，读取失败不会被当作确认无任务。

## 解释结果

| 观察结果 | 检查方向 |
| --- | --- |
| 已保存的任务开关关闭 | 核对实际开关与运行实例。 |
| HUD 未运行、存在多实例或版本不符 | 检查实际应用与启动路径。 |
| 数据库不存在、字段不兼容或读取失败 | 检查数据目录、权限和宿主记录格式。 |
| 新会话不在脚本候选中 | 核查来源筛选、索引更新时间与脚本的 32 项候选上限；不能直接推断当前 HUD 也排除了它。 |
| 新任务只有工具或 Token 事件，没有开始事件 | 检查开始事件是否及时落盘、是否遗漏或超出脚本读取范围。 |
| 开始事件的 ID 或时间戳无效 | 检查宿主记录格式与解析兼容性。 |
| 独立推算显示运行中，界面仍为空 | 结合应用内诊断，检查运行实例、状态接收与显示链路。 |
| 只有采集前的历史开始，没有新的明确开始 | 脚本会保留未知；不能将其零值直接解释为 HUD 漏计。 |

`independentModelRunning` 是脚本自采集开始后的普通日志推算，不是 HUD 内存、真实任务总量或 Touch Bar 渲染结果。Hooks 模式下它只帮助检查日志，不验证真实 Hook 配置、接入或投递。

报告采用逐行 JSON，并包含最终 footer。`completed:false` 或缺少 footer 表示采集未完整结束；已有样本仍可分析。脚本使用 macOS 自带 SQLite 的 `-readonly -json` 能力，不支持时记录失败。

## 开发验证

`python3 Tests/TaskDiagnosticProbeTests.py` 使用隔离数据验证基线、增量读取、迟到事件、有界尾读、截断、路径约束与隐私输出，以及数据库缺失、结构不兼容和成功空结果的区别。模拟进程变化不会重启本机应用。Python 仅用于开发测试，分发脚本不依赖 Python。
