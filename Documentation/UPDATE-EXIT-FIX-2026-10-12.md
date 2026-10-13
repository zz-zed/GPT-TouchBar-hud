# 自动更新等待旧进程退出失败：诊断与本地修复

2026-10-12 历史诊断与安装记录。已复现并修复异步退出确认无法执行的问题，相关回归通过。用户授权后，已完整备份旧版并将本机正式应用替换为当时的本地修复版 `0.1.42 / Build 45`，正常退出与重新启动验证通过；当时未提交、推送或发布。2026-10-13 将本修复整合进 v0.1.44，当前发布状态见[版本记录](RELEASE-0.1.44.md)。

## 现场证据

初始现场运行 `/Applications/GPT TouchBar HUD.app`，版本为 `0.1.41 / Build 44`。更新会话 `8EECF3B1-A15F-4C1A-B383-E2A76E15D16B` 的目标是 `v0.1.42 / Build 45`。下载与校验已通过，`new.app` 已准备好；安装器等待旧进程 60 秒后，将状态写为 `failed / waitingForExit / untouched`。该失败会话未生成 `previous.app`，当时原应用仍在正式安装位置；失败会话与证据继续保留。

对旧进程 `73095` 采样，主线程持续停在以下调用链：

```text
AppUpdateInstallation.prepareDiagnosticHandoff
  → AppUpdateInstallation.handoff
  → AppUpdater.onInstall
  → AppDelegate.onInstall
  → NSApplication.terminate
  → NSApplication._shouldTerminate
  → nested run loop
```

`applicationShouldTerminate` 返回 `.terminateLater`，随后通过主队列发送退出确认；3 秒超时也使用主队列。此次安装交接本身正在执行主队列回调，等待期间该队列不能重入，退出确认与超时保护均无法执行。诊断落盘完成和消息缓存落盘完成的退出回调也经过这条主队列。

Apple 的 [terminateLater 文档](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater)说明，等待期间 AppKit 运行 `NSModalPanelRunLoopMode`，直到收到退出确认。独立原生程序在本机复现：原主队列回调方案直到外部 watchdog 结束时仍未退出，退出码为 `70`；向终止等待模式注册的 RunLoop timer 正常送达确认，退出码为 `0`。

## 修复范围

- `Sources/MainRunLoopCompletion.swift`：在普通公共模式与 AppKit 终止等待模式下送达回调，以 RunLoop timer 保持原有截止时间；完成、超时及重复/迟到回调共享一次完成保护。
- `Sources/AppDelegate.swift`：聚合消息缓存与诊断落盘完成后，通过上述机制确认退出；整体截止时间仍为 3 秒。
- `Sources/DiagnosticUpgradeRecovery.swift`、`Sources/ResetNewsRepository.swift`：退出所需的落盘回调同样送达主 RunLoop，避免正常落盘完成后只能等待超时。
- 新增真实 AppKit 退出回归，并接入 `test-app-update.sh`；更新独立回归编译入口的源文件依赖。

安装脚本的目标路径校验、60 秒退出检查、旧版备份、替换与启动确认规则均保持原有实现。本次修复没有引入安装器强制结束旧进程的行为。

## 验证

| 检查 | 结果 |
| --- | --- |
| 更新策略 | 82 项通过 |
| 隔离安装器保护 | 42 项通过 |
| 更新进度、下载、助手和原生窗口 | 223 项通过 |
| 诊断恢复 | 25 项通过 |
| 诊断安装器实际脚本场景 | 138 项通过，覆盖 12 个场景 |
| 消息缓存与通知运行时 | 453 项通过，网络与通知使用注入夹具 |
| 原生异步退出 | 4 个独立进程场景通过 |
| 缓存迁移编译入口 | 使用隔离空缓存夹具执行成功 |
| 变更格式 | `git diff --check` 通过 |

共 963 项已有检查通过，另有 4 个原生 AppKit 退出场景。原生测试从主队列调用真实 `NSApplication.terminate`，使用真实 `ResetNewsRepository` 写入与 flush，覆盖正常完成、另一路写入不响应时按截止时间退出、迟到完成、重复完成；确认回调在主线程执行一次，缓存仍保留。测试不启动或结束本机已安装的 HUD。

验证日志与现场原始证据保存在 `build/update-exit-fix-20261012/evidence/`，包括进程采样、失败会话状态、各项回归输出与构建记录。

## 本地修复包

候选路径为 `build/update-exit-fix-20261012/GPT TouchBar HUD.app`。该包沿用当前源码的 `0.1.42 / Build 45`，包含本次未发布补丁，与公开 v0.1.42 二进制不同；通过 `HUDSourceSHA256` 区分源码内容。本次没有修改版本号或发布说明。

最终候选的完整构建、严格签名、arm64 架构、macOS 11 最低系统标记和源码摘要核对结果记录在 `evidence/candidate-verification.json`。

## 备份、安装与实际退出验证

用户明确授权“备份旧版后安装修复后的 0.1.42，并验证退出和重启流程是否正常”。先用 `ditto` 保留完整旧版应用，并核对全包文件哈希、大小、权限、目录及符号链接和严格签名，再处理卡住的旧进程。旧进程 `73095` 已确认身份与原二进制哈希，使用一次 `SIGTERM` 恢复；新版的退出验证均使用正常退出路径。

安装前创建了完整旧版备份 `backups/update-exit-repair-20261012-8FEAB7A1.noindex/GPT TouchBar HUD 0.1.41.app`，同目录保留 `bundle-inventory.json` 和说明。安装器还在 `/Applications/.GPTTouchBarHUD-update-8FEAB7A1-EAC5-43E6-87A0-EEF545C7454E/previous.app` 创建第二份旧版；安装后检查两份均与原始清单一致。

使用修复包自带的正式安装脚本完成替换。会话 `8FEAB7A1-EAC5-43E6-87A0-EEF545C7454E` 于 13:34:29 完成，退出码为 `0`，状态为 `succeeded / finished / backupRetained`，收到新版 `0.1.42` 的实际启动回执。

| 实际安装后检查 | 结果 |
| --- | --- |
| 正式安装位置 | `/Applications/GPT TouchBar HUD.app`，`0.1.42 / Build 45` |
| 包内容及签名 | 全包与修复候选一致，严格签名通过，主程序和助手哈希一致 |
| 正常系统退出请求 | 请求被接受，`NSRunningApplication` 在约 4.17 秒后报告终止 |
| 应用内“退出 App” | OS 进程检查确认约 0.32 秒退出，诊断会话记录正常关闭 |
| 手动退出后自动启动 | 连续观察 6.21 秒无进程重新出现，手动退出标记正常保留 |
| 明确重新打开 | 新进程 `86336` 完成启动，设置窗口正常出现，只有一个正式实例 |
| 启动状态恢复 | 新诊断会话建立，手动退出标记清除；随宿主启动的偏好仍开启 |

首次系统退出检查使用了额外的 4 秒观察阈值，虽然退出成功，检查仍因耗时超过阈值提前停止；原始记录保留在 `quit-normal-api-first.json`。首次自动启动检查使用 NSWorkspace 状态，结果不明确，记录同样保留；最终验证改用实际 OS 进程存在性，完成了上述连续观察。退出后的界面读取曾超时，明确重新打开后已成功读取设置窗口。

安装和最终验证记录保留在本地 `build/update-exit-fix-20261012/evidence/installed-verification.json`。本机 ARM64 实测通过；Intel 与真实 macOS 11 环境未运行本次补丁，macOS 11 编译目标和包内标记不等于真机验收。

## 后续旧版清理

用户随后明确“旧版不要了”。13:51:59 核对两份备份均为 `0.1.41 / Build 44`、与原始文件清单一致且没有运行进程后，通过 macOS 废纸篓接口移走这两份应用。原备份位置已无应用，清单、诊断和安装验证记录继续保留；`installed-verification.json` 的备份信息是清理前的历史快照。当前正式 `0.1.42` 仍正常运行，进程 `86336` 未受影响。

清理结果及废纸篓实际位置保留在本地 `build/update-exit-fix-20261012/evidence/backup-disposal-result.json`。
