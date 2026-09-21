# 卸载与清理

[返回 README](../README.md) · [使用指南](USER-GUIDE.md) · [数据与隐私](DATA-AND-PRIVACY.md)

**删除 App 不等于删除所有自动启动项、偏好和可选 Hooks 文件。** 本页将“停止使用”“清理 Hooks”“卸载应用”和“清理可选数据”分开，避免误删其他工具的配置。

所有命令均供用户审阅后在自己的 Mac 上手动执行。不要使用 `sudo`、批量删除整个 Codex 目录，或删除无法确认归属的文件。

## 只想暂时停止使用

在菜单栏选择“退出”。本轮 ChatGPT / Codex 宿主会话内，本工具不会再次自动拉起；宿主完全退出后，该手动退出状态解除，下次启动宿主仍可能自动启动本工具。

只想隐藏面板时，使用“隐藏状态面板”；隐藏不等于退出，也不关闭任务监测。只想停止任务日志读取时，关闭“设置 → 通用 → 显示任务状态（实验性）”。

## 启用过 Hooks 时先清理配置

没有启用、审阅应用过 Hooks 配置的用户可跳过本节。**仅打开过 Hooks 配置窗口，不代表已经写入配置或安装 helper。** 但一次应用失败也可能留下已复制的 helper 或备份，出现过该情况时仍应审阅残留。

清理配置应在删除 App 之前进行：

1. 在“设置 → 实验”打开 Hooks 配置窗口，关闭“启用实验性任务监测”。关闭后恢复默认日志模式，并不删除配置。
2. 点击“审阅本工具配置清理”，核对目标文件、命令与合并后的 JSON。默认目标为 `$CODEX_HOME/hooks.json`；未设置该环境变量时为 `~/.codex/hooks.json`。
3. 确认无误后点击“应用已审阅清理并关闭”，核对结果提示并保留必要的配置备份。

清理只移除精确匹配、归属本工具且未被修改的定义，保留其他 Hooks 和用户修改过的条目。生成计划失败时，不要手工删除整个 `hooks.json`；先检查路径、JSON 格式和被修改的条目，必要时请维护者协助。

**该界面清理的是配置，不会自动删除稳定 helper、缓存或备份。** 完成配置清理后，先确认没有仍保留的条目引用本工具的 helper，再考虑后续文件清理。详细规则见[Hooks 实验说明](HOOKS-EXPERIMENT.md)。

## 停用自动启动项并移除应用

完成所需的 Hooks 清理后，在菜单栏退出本工具。下面的自动启动项仅针对当前用户：

```text
~/Library/LaunchAgents/io.github.zz-zed.GPTTouchBarHUD.CodexLauncher.plist
```

可先在终端进行**只读查看**，确认 `Label` 和启动命令属于 GPT TouchBar HUD：

```bash
plutil -p "$HOME/Library/LaunchAgents/io.github.zz-zed.GPTTouchBarHUD.CodexLauncher.plist"
```

确认后，卸载当前用户图形会话中的注册项：

```bash
launchctl bootout "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/io.github.zz-zed.GPTTouchBarHUD.CodexLauncher.plist"
```

如果文件不存在或任务本来就未加载，命令可能报错；先核对具体错误和实际状态，不要通过提高权限或删除其他注册项来强行处理。

然后在 Finder 的“前往文件夹”中打开 `~/Library/LaunchAgents/`，将上述**确切文件**移到废纸篓。再到安装目录，将 `GPT TouchBar HUD.app` 移到废纸篓。

使用默认安装方式时应用位于 `/Applications`；安装在 `~/Applications` 的用户应移除对应位置的副本。避免同时保留并运行另一份 App，否则再次运行可能重新注册自动启动项。

仅停用注册项而保留 App 时，今后手动运行应用仍可能重新安装注册项；这不等于一个永久关闭自动启动的设置开关。

## 可选清理偏好缓存与更新备份

卸载后可以保留这些内容，方便将来重装或排查。需要清理时，先确认应用和实验接收已经停止，再逐项审阅。

| 内容 | 位置 | 注意事项 |
| --- | --- | --- |
| 当前应用退出标记 | `~/Library/Application Support/GPT TouchBar HUD/manual-quit.lock` | 只处理已确认归属的文件。 |
| Hooks 稳定文件 | `~/Library/Application Support/GPTTouchBarHUD/Hooks/` | 与上一行目录不同；先确认配置中没有残留命令引用 helper，再核对安装回执。 |
| Hooks 运行缓存 | `~/.gpt-touchbar-hud-hooks/` | 可能包含 socket、锁和 `state.json`；停用后审阅，不在运行时清理。 |
| 更新备份与日志 | 安装目录同级 `.GPTTouchBarHUD-update-<随机标识>/` | 可能含 `previous.app` 和 `install.log`；不需要恢复或排查后再清理，不在更新期间删除。 |
| Hooks 配置备份 | 清理或安装界面提示的时间戳备份路径 | 可能包含同一文件中其他工具的配置；不要覆盖现有配置或批量删除。 |

稳定 helper 的项目内卸载逻辑只移除与安装回执匹配、未被修改的可执行文件；它不是当前设置窗口中的“一键完整卸载”按钮。普通用户手动清理前应确认配置引用和文件归属，无法确认时保留文件并向维护者求助，不要递归删除整个 Application Support 或 Codex 目录。

需要清除本工具的 UserDefaults 时，在退出应用后运行：

```bash
defaults delete io.github.zz-zed.GPTTouchBarHUD
```

这会删除本工具已保存的界面、任务显示与更新等偏好，不会替你清理 Hooks 配置或自动启动项。若偏好域不存在，无需重复执行。

旧项目兼容目录 `~/Library/Application Support/TouchBarCodexToken/` 可能保留手动退出标记；旧的 LaunchAgent 标签为 `com.jackchen.TouchBarCodexToken.CodexLauncher`。当前应用会在迁移时尝试停用旧项。若你仍使用旧项目，不要把它的目录、应用或偏好当作本工具残留批量清理。

## 清理后的检查

确认本工具已退出，当前用户 LaunchAgents 目录中不再有本工具的注册文件；启用过 Hooks 时，确认配置中不再有要移除的 helper 引用，并且没有重新启用实验。

重新启动 ChatGPT / Codex 后，本工具不应因已移除的注册项自动打开。如果仍出现，请先检查是否还运行着另一份 App 或存在已知旧项目的注册项，再提供具体路径和应用版本反馈，不要用通配符删除其他启动项。

实现参考：[启动注册](../Sources/HostAutoLauncher.swift)、[应用标识与旧版迁移](../Sources/AppIdentity.swift)、[Hooks 清理界面](../Sources/HookExperimentPreferencesController.swift)。
