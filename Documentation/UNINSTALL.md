# 卸载与本地清理

[返回首页](../README.md) · [数据与隐私](DATA-AND-PRIVACY.md)

删除 App 不会自动移除自动启动项、已经启用的 Hooks 或更新备份。按下面顺序处理；没有启用过 Hooks 的用户可跳过第一节。以下操作仅针对 GPT TouchBar HUD，不需要退出账号或删除 Codex 会话。

## 1. 如果启用过 Hooks，先清理配置

在删除 App 前完成：

1. 打开“设置 → 实验”中的 Hooks 配置窗口。
2. 关闭“启用实验性任务监测”，停止接收事件并恢复默认日志模式。
3. 点击“审阅本工具配置清理”，核对目标文件及清理后的完整内容。
4. 点击“应用已审阅清理并关闭”。确认界面提示已移除匹配的定义。

默认配置文件为 `~/.codex/hooks.json`；设置过 `CODEX_HOME` 时，以界面实际显示的路径为准。清理只移除与本工具定义精确匹配的条目，保留其他 Hook 和被修改过的条目。若无法生成计划或仍有被修改的条目，先核对文件与命令，必要时[反馈问题](https://github.com/zz-zed/GPT-TouchBar-hud/issues)，不要直接删除整个 `hooks.json`。

配置写入或清理前会产生带时间戳的 `hooks.json.gpt-hud-…backup`。确认不再需要回滚后，可单独删除对应备份；它可能包含原文件中的其他配置，不要上传原文。

**这个界面清理的是配置，不会自动删除稳定 helper、安装回执和缓存。**它们的处理见第四节。实现与覆盖范围见 [Hooks 实验说明](HOOKS-EXPERIMENT.md)。

## 2. 退出工具并移除自动启动项

先从菜单栏选择“退出”。仅隐藏面板不会退出应用，也不会停止自动启动。

在终端运行下面的命令，卸载当前用户的启动服务：

```sh
launchctl bootout "gui/$(id -u)/io.github.zz-zed.GPTTouchBarHUD.CodexLauncher"
```

如果提示服务不存在，可能已经卸载或从未注册；继续检查以下文件。在 Finder 使用“前往 → 前往文件夹”，找到并将这一个文件移到废纸篓：

```text
~/Library/LaunchAgents/io.github.zz-zed.GPTTouchBarHUD.CodexLauncher.plist
```

曾安装旧名 TouchBarCodexToken 的用户，可检查旧启动项是否仍存在。新版启动时通常已清理它；如仍存在，再卸载对应服务并移走这一旧文件：

```sh
launchctl bootout "gui/$(id -u)/com.jackchen.TouchBarCodexToken.CodexLauncher"
```

```text
~/Library/LaunchAgents/com.jackchen.TouchBarCodexToken.CodexLauncher.plist
```

不要删除 `LaunchAgents` 整个目录。移除启动项后，重新打开本工具会再次注册它；准备卸载时不要再启动。

## 3. 删除应用

在 Finder 将实际安装位置中的 `GPT TouchBar HUD.app` 移到废纸篓，通常位于 `/Applications` 或 `~/Applications`。有多份副本时，分别核对名称和位置。

确认菜单栏图标已消失，Touch Bar 常驻额度条已释放。ChatGPT / Codex 客户端与账号数据不需要删除。

## 4. 可选：移除偏好、缓存与备份

这些材料不会因删除 App 自动消失。需要保留设置以便重装时，可以留下偏好；需要完全清理时，先确认工具已退出且 Hooks 配置已经处理。

| 材料 | 位置与处理方式 |
| --- | --- |
| 当前偏好及更新检查状态 | `io.github.zz-zed.GPTTouchBarHUD` 的 UserDefaults 域；删除后重装会恢复默认设置。 |
| 旧版偏好 | `com.jackchen.TouchBarCodexToken` 域；只在不再使用旧版且不需要迁移设置时删除。 |
| 手动退出标记 | `~/Library/Application Support/GPT TouchBar HUD/manual-quit.lock` 与 `~/Library/Application Support/TouchBarCodexToken/manual-quit.lock`；可删除这些文件。 |
| Hooks 稳定 helper 与回执 | `~/Library/Application Support/GPTTouchBarHUD/Hooks/`，注意这里的 `GPTTouchBarHUD` **没有空格**。见下方核对步骤。 |
| Hooks 生命周期缓存与 IPC 文件 | `~/.gpt-touchbar-hud-hooks/`；在工具退出且配置已清理后，核对其中的 `state.json`、socket、锁等本工具文件，再移到废纸篓。 |
| 更新恢复材料 | 实际安装目录同级的 `.GPTTouchBarHUD-update-<随机标识>/`；可包含 `previous.app`、下载包、安装日志或失败恢复文件。确认无需回滚后逐个清理。 |
| 安装包与挂载卷 | 弹出安装卷，再按需删除下载目录中的 DMG。 |

如决定清除当前偏好，在工具退出后执行：

```sh
defaults delete io.github.zz-zed.GPTTouchBarHUD
```

只有确实不再需要旧版设置时，才执行：

```sh
defaults delete com.jackchen.TouchBarCodexToken
```

提示域不存在时无需创建任何文件。

### 核对 Hooks helper 的归属

稳定 helper 安装后会生成 `installation.json`，其中 `installedDigest` 记录当前 helper 的 SHA-256。可以只读查看本地回执，并计算摘要：

```sh
shasum -a 256 "$HOME/Library/Application Support/GPTTouchBarHUD/Hooks/HookEmitter"
```

确认摘要与 `installation.json` 的 `installedDigest` 一致，且所有本工具 Hook 命令已清理后，再将 `HookEmitter` 移到废纸篓。`HookEmitter.previous` 是可能存在的旧 helper，`previousDigest` 用于核对它；安装回执和旧 helper 可以保留到确认不再需要回滚时再删除。回执缺失、摘要不符或目录内有无法确认归属的文件时，先保留并核对，不将它们视为可自动删除的缓存。

当前 App 没有“一键删除所有 helper 文件”的用户入口；不要把“应用已审阅清理并关闭”理解为完成了这一节的文件清理。

## 5. 确认卸载结果

- 菜单栏图标和 Touch Bar 额度条已消失。
- 两个相关 LaunchAgent 文件不再存在；重启宿主后工具不再自动启动。
- 若启用过 Hooks，宿主配置中不再有本工具命令，其他 Hook 保持原样。
- 仅清理了本工具的偏好、文件和已确认的备份，没有删除 `~/.codex`、Codex 任务记录或整个 Application Support 目录。

只想暂时不用时，可选择菜单“退出”，无需执行卸载。仅想不读取任务日志时，在“设置 → 通用”关闭任务状态即可。
