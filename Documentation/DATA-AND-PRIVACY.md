# 数据来源、隐私与排查

[返回 README](../README.md) · [使用指南](USER-GUIDE.md) · [更新与恢复](UPDATING.md) · [卸载与清理](UNINSTALL.md)

## 额度与账号用量

额度和 Token 数据通过 ChatGPT / Codex 客户端随附的本机 `codex app-server` 获取。本工具以子进程方式启动 `codex app-server --listen stdio://`，通过 JSON-RPC 读取数据，不直接处理登录凭据。

按顺序查找以下本机程序：

```text
/Applications/ChatGPT.app/Contents/Resources/codex
/Applications/Codex.app/Contents/Resources/codex
/Applications/GPT.app/Contents/Resources/codex
```

这些路径和接口是当前实现的接入条件，不是对所有历史或未来客户端版本的兼容承诺。仅在浏览器中登录，或仅安装不在这些路径中的独立 CLI，不满足当前自动发现条件。

| 指标 | 数据来源与口径 |
| --- | --- |
| 5 小时 / 周额度 | `account/rateLimits/read` 返回的额度窗口，按窗口时长识别；不把一个周窗口重复显示为 5 小时窗口。 |
| 完整重置次数 | `rateLimitResetCredits` 中当前可用的完整重置次数及最早到期时间。 |
| 点数余额 | 额度快照中的 `credits.balance`；余额为 0、无限额度或字段缺失时不显示。 |
| 昨日 Token | `account/usage/read` 的昨日每日桶，按当前系统日历匹配日期。 |
| 累计 Token | `account/usage/read` 返回的账号累计值，不用有限天数的每日桶求和代替。 |

Token 是接口返回的账号统计，不是对当前电脑的本地会话日志求和。账号 Token 日期桶的服务端全局时区规则没有公开承诺，当前按本机日历匹配“昨日”。同一邮箱、同一套餐下的 workspace 切换主要依赖宿主发出的账号变更通知。

### 刷新与缺失数据

额度通常每 60 秒刷新，同时响应 app-server 的额度更新通知。账号 Token 通常每 5 分钟刷新；手动刷新 Token 的最短间隔为 10 秒，避免连续点击产生过多请求。

Token 请求失败后按 5、10、20、30 分钟逐步退避。短暂失败时尽量保留上次数据，不把无法确认的值当作 0。

| 显示 | 含义 |
| --- | --- |
| Token 后的 `*` | 本次刷新失败，显示上次成功结果；不代表数据是实时的。 |
| `--` | 数据缺失或无法确认，不等于 0。 |
| 不显示某一额度窗口 | 当前账号未返回该窗口，不一定是读取故障。 |
| 不显示点数 | 余额为 0、无限额度或字段缺失。 |

## 额度与用量读取排查

先确认实际使用的客户端安装在系统 `/Applications` 中、已经登录，随后通过本工具菜单栏“刷新额度”重试。

持续显示 `--` 时，区分“所有数据都缺失”和“只缺某个接口的数据”。前者需要检查本机运行程序和登录态；后者可能是当前客户端或账号没有提供对应字段。应用不会用任务日志伪造缺失的账号 Token 统计。

需要进一步确认本机运行程序是否存在时，可在终端运行以下**只读检查**。它不会启动 app-server、修改设置或输出账号凭据：

```bash
for runtime in \
  "/Applications/ChatGPT.app/Contents/Resources/codex" \
  "/Applications/Codex.app/Contents/Resources/codex" \
  "/Applications/GPT.app/Contents/Resources/codex"
do
  if [ -x "$runtime" ]; then
    printf '可执行：%s\n' "$runtime"
  else
    printf '不存在或不可执行：%s\n' "$runtime"
  fi
done
```

找到可执行文件只说明发现条件满足，不代表接口返回、账户权限或登录状态已验证。仍无法读取时，请[提交 Issue](https://github.com/zz-zed/GPT-TouchBar-hud/issues)，提供客户端版本、应用版本、macOS 版本、芯片类型和缺失的数据项，不要附上登录文件、令牌或未经脱敏的对话日志。

## 任务状态的读取与判断边界

任务状态与账号额度 / Token 统计是两套独立数据来源。“设置 → 通用 → 显示任务状态（实验性）”默认开启；关闭后停止任务监测相关读取，不影响额度和 Token 请求。

### 默认日志模式

只依据本机 Codex 最近 **32 个未归档任务**的索引与近期日志推断，不代表所有 ChatGPT 网页、远程任务或账号任务。

首次发现时，仅最近 30 分钟有日志更新的任务参与指示；更早的历史记录不影响当前展示，也不代表已确认其结束。监测期间有新增日志的任务继续参与判断。

新增任务通常在 10 秒内被发现，已发现任务每 2 秒检查新增日志；单个文件每次最多读取 256 KiB。日志证据不足、个别文件读取失败或整体监测暂不可用时，不额外展示问号或诊断提示；没有已确认执行中任务时保持中性图标，不影响额度读取。

运行中的任务连续 30 分钟没有有效执行证据后退出实时执行数，仅在内部保留未确认记录；后续出现新执行证据时重新参与计数。静默不是结束或失败的证据，不会因此触发完成提示。

正常监测时优先展示执行中数量；最后一个任务完成后显示约 4 秒的完成提示，随后恢复中性图标，表示“当前未检测到执行中任务”。未确认记录不会在完成提示结束后变成主问号，也不单独展示诊断。明确中止不显示完成提示，重启或重复读取历史完成事件也不重播提示。整体监测故障也不单独提示；不能因此推断任务完成。

“本轮完成”不等于整个目标完成。当前不识别等待审批、等待输入或失败，也不提供进度百分比。该功能依赖未公开承诺稳定的本地记录格式，宿主升级后可能需要适配。

### 可选 Hooks 模式

Hooks 默认关闭。只有审阅并应用计划后才写配置和安装稳定 helper；启用后用事件触发状态核对，**仍会有界读取本机任务索引与日志**，不是完全不读日志的监测模式。

模式分别展示执行中、已提交待核对、未知、覆盖范围与连接健康。覆盖不完整时保留未知提示和原因，不把连接正常解释成全量覆盖或精确零任务。新完成反馈约 4 秒后消失，不因刷新或重新显示而重播；同轮继续执行会撤销反馈。

关闭 Hooks 会停止实验接收并恢复默认日志模式，不会自动清理已写入配置和 helper。关闭总的任务状态显示才停止任务监测。真实宿主执行、准确性、延迟和长期能耗尚未验收，没有省电收益结论。具体机制、资源上限及覆盖边界见[Hooks 实验说明](HOOKS-EXPERIMENT.md)。

## 工作原理概览

```text
已登录的 ChatGPT / Codex 客户端        本机 Codex 任务
              │                       ├─ 任务索引与近期日志（默认）
       codex app-server               └─ 已审阅启用的 Hooks（可选）
              │                                   │
   额度与账号用量接口                    事件触发核对，仍有界读取日志
              │                                   │
              └────────────────┬──────────────────┘
                               ▼
                       GPT TouchBar HUD
                        ├─ macOS 菜单栏
                        ├─ 刘海面板（可用时）
                        ├─ 桌面浮窗（按需显示）
                        └─ Touch Bar（对应硬件）
```

## 隐私与联网

本工具不保存密码、API Key、授权码或访问令牌，不抓取网页，也不会上传本机会话日志。

本机 app-server 使用客户端已有登录态访问服务端，额度与 Token 展示数据保留在本工具的进程内存中。因此“通过本机组件获取”不等于“完全离线”。

任务监测只读访问本机任务索引与近期日志片段，提取有限的生命周期信息和时间戳，不展示、另存或上传对话正文。关闭任务状态显示后停止读取。

Hooks helper 不转发或持久化提示词、回复、工具参数、工作目录或转录路径；事件和缓存保存任务生命周期元数据。实验不绕过宿主的信任机制。

自动检查更新开启且应用位于受支持安装路径时，会访问本仓库公开的 GitHub Release API，并在 User-Agent 中包含应用版本；必要时按规则回退最新 Release 页面。检查不携带 ChatGPT 账号信息或任务内容，不自动下载附件。只有用户主动确认安装后才下载。开发构建、测试和刘海模拟入口不启动自动检查；在设置 → 更新中可关闭该功能。

## 本机保存哪些内容？

| 内容 | 位置或保存方式 | 清理注意事项 |
| --- | --- | --- |
| 界面、任务显示、更新偏好和检查状态 | 应用的 UserDefaults。 | 删除后会失去已保存设置。 |
| 随宿主自动启动的注册项 | `~/Library/LaunchAgents/io.github.zz-zed.GPTTouchBarHUD.CodexLauncher.plist`。 | 卸载时应停用并清理。 |
| 当前应用手动退出标记 | `~/Library/Application Support/GPT TouchBar HUD/manual-quit.lock`。 | 与下面不带空格的 Hooks 目录不同。 |
| 旧项目兼容退出标记 | `~/Library/Application Support/TouchBarCodexToken/manual-quit.lock`。 | 仍使用旧项目时不要批量删除其目录或偏好。 |
| 更新暂存、日志与旧应用备份 | 安装目录同级的 `.GPTTouchBarHUD-update-<随机标识>/`。 | 确认安装更新后才创建；可能保留 `install.log`、`previous.app` 或失败恢复材料，不自动删除备份。 |
| Hooks 配置及时间戳备份 | 默认 `$CODEX_HOME/hooks.json`，未设置时为 `~/.codex/hooks.json`。 | 仅审阅应用后写入；清理不得破坏其他工具的 Hooks。 |
| Hooks 稳定 helper、安装回执与回滚材料 | `~/Library/Application Support/GPTTouchBarHUD/Hooks/`。 | 不随删除 App 自动移除；用户修改过的内容需单独审阅。 |
| Hooks socket、锁和 `state.json` 元数据缓存 | `~/.gpt-touchbar-hud-hooks/`。 | 与账号用量内存缓存不同；停用实验后再审阅清理。 |

Hooks 配置清理、稳定 helper 清理、应用卸载是不同操作。关闭实验不会自动删除配置、备份或 helper；详细步骤见[卸载与清理](UNINSTALL.md)。

## 实现与验证入口

额度接入见[客户端实现](../Sources/CodexAppServerClient.swift)，应用目录与身份见[应用标识](../Sources/AppIdentity.swift)，启动注册见[自动启动实现](../Sources/HostAutoLauncher.swift)。

Hooks 写入与隐私边界见[实验说明](HOOKS-EXPERIMENT.md)；发布与真机验收范围见[v0.1.30 发布记录](RELEASE-0.1.30.md)。
