# 开发、构建与验证

[返回项目说明](../README.md)

本文面向希望阅读、构建或验证 GPT TouchBar HUD **v0.1.30 / Build 33** 源码的开发者。发布安装和日常使用见[使用指南](USER-GUIDE.md)，数据边界见[数据与隐私](DATA-AND-PRIVACY.md)。

## 工作原理

```text
ChatGPT / Codex 本机登录态             本机 Codex 任务
              │                         ├─ 任务索引与近期日志（默认）
              ▼                         └─ 已审阅并启用的 Hooks（可选）
       codex app-server                           │
              │                                   │
   ┌──────────┴──────────┐                        │
   │                     │                        │
account/rateLimits/read  account/usage/read       │
   │                     │                        │
   └──────────┬──────────┘                        │
              └────────────────┬──────────────────┘
                               ▼
                       GPT TouchBar HUD
                        ├─ macOS 菜单栏
                        ├─ 刘海融合面板（可用时）
                        ├─ 桌面 HUD（可选）
                        └─ Touch Bar（有对应硬件时）
```

主应用以菜单栏配件运行。`CodexAppServerClient` 管理本机 `codex app-server --listen stdio://` 子进程；额度和 Token 通过 JSON-RPC 获取。任务监测默认读取本机索引和近期日志。Hooks 实验默认关闭，应用后只提供生命周期信号，状态协调器仍会对本机索引和日志做有界核对。

## 源码结构

| 路径 | 作用 |
| --- | --- |
| `Sources/AppDelegate.swift` | 应用生命周期、菜单、设置、HUD 和更新器的顶层连接。 |
| `Sources/CodexAppServerClient.swift` | 启动本机 app-server 并处理 JSON-RPC。 |
| `Sources/RateLimitStore.swift`、`Sources/LimitModels.swift` | 额度、重置次数和点数模型与刷新。 |
| `Sources/AccountTokenUsage.swift` | 账号 Token 用量模型和刷新状态。 |
| `Sources/TaskMonitoringCoordinator.swift`、`Sources/TaskStatusMonitor.swift` | 默认日志模式与可选 Hooks 状态协调。 |
| `Sources/HUDPresentation.swift` | 自动、刘海和桌面浮窗显示模式及保存规则。 |
| `Sources/CompactHUDPanel.swift`、`Sources/CompactHUDViewController.swift` | 桌面浮窗。 |
| `Sources/NotchHUDController.swift`、`Sources/NotchPresentationModel.swift` | 刘海面板控制、Compact / Peek / Expanded 状态。 |
| `Sources/NotchLayout.swift`、`Sources/NotchSurfaceShape.swift`、`Sources/NotchInteractionController.swift` | 刘海几何、渲染轮廓和交互区域。 |
| `Sources/PersistentTouchBarController.swift`、`Sources/SystemTouchBarPresenter.swift` | Touch Bar 常驻和系统控制条协作。 |
| `Sources/PreferencesWindowController.swift` | 通用、外观、Touch Bar、实验和更新设置。 |
| `Sources/AppUpdater.swift`、`Sources/AppUpdateModels.swift`、`Sources/AppUpdateScheduler.swift` | 更新发现、计划、校验、替换和恢复。 |
| `Sources/HostAutoLauncher.swift`、`Sources/HostLifecycleMonitor.swift` | LaunchAgent、宿主生命周期和手动退出状态。 |
| `HookCore/`、`HookHelper/` | 可选 Hooks 协议、状态缓存和稳定 helper。 |
| `Resources/` | App bundle 元数据、图标和随包资源。 |
| `scripts/` | 构建、打包、预览和回归脚本。 |

刘海实现的几何和状态细节见[原生刘海实现与验证](NotchIsland/README.md)，Hooks 协议和安全边界见[Hooks 实验说明](HOOKS-EXPERIMENT.md)。

## 本地构建

需要 macOS、Xcode Command Line Tools 和 Swift 5.8 或更新版本。

```bash
git clone https://github.com/zz-zed/GPT-TouchBar-hud.git
cd GPT-TouchBar-hud
scripts/build-app.sh
open "build/GPT TouchBar HUD.app"
```

`scripts/build-app.sh` 从 `Resources/Info.plist` 读取最低系统版本，使用显式 SDK 和目标版本编译优化后的主应用及原生 helper，再分别签名并验证。默认只构建当前机器架构。如果本机工具链具备两种目标架构及相应兼容库，可以构建通用包：

```bash
HUD_BUILD_ARCHS='arm64 x86_64' scripts/build-app.sh
```

打包 DMG：

```bash
scripts/package-dmg.sh
```

输出位于：

```text
dist/GPT-TouchBar-HUD-<版本号>.dmg
```

生产构建会包含 HookCore 和 HookHelper，但 Hooks 默认关闭；默认任务状态仍使用日志模式。早期实验程序不进入正式应用包。

## 回归脚本

仓库提供以下现有检查：

```bash
bash scripts/test-app-migration.sh
bash scripts/test-account-token-usage.sh
bash scripts/test-token-usage.sh
bash scripts/test-task-status.sh
bash scripts/test-app-update.sh
bash scripts/test-touchbar-layout.sh
bash scripts/test-touchbar.sh
bash scripts/test-design-layout.sh
bash scripts/test-notch-hud.sh
bash scripts/test-notch-presentation.sh
bash scripts/test-hooks.sh
bash scripts/test-hook-integration.sh
bash scripts/test-hook-installer.sh
```

`test-hook-installer.sh` 依赖正式 App bundle 中的 helper。运行它之前先执行：

```bash
scripts/build-app.sh
```

确保以下文件已经生成：

```text
build/GPT TouchBar HUD.app/Contents/Helpers/HookEmitter
```

`test-touchbar.sh --smoke-system` 需要真实图形会话和兼容系统，会短暂呈现 Touch Bar 项目。涉及 AppKit 窗口或系统事件的测试不应并发运行，以免互相抢占前台或污染点击结果。

## 刘海原生预览

启动原生预览：

```bash
bash scripts/test-notch-presentation.sh --preview --debug-regions
```

fixture 默认使用 Peek。要检查 Compact 静止态，传入：

```bash
bash scripts/test-notch-presentation.sh --preview --compact --debug-regions
```

常用参数示例：

```bash
bash scripts/test-notch-presentation.sh --preview \
  --width 640 \
  --height 600 \
  --notch-width 180 \
  --physical-inset 38 \
  --visual-height 24 \
  --compact \
  --english
```

还可以用 `--reduced-motion`、`--reduced-transparency` 和 `--low-power` 检查相应系统条件。旧的 `--always-peek` 参数继续兼容；与 `--compact` 同时出现时，Compact 优先。

预览使用固定演示数据和合成屏幕几何，不连接 Hooks、网络、LaunchAgent 或更新器。窗口位于真实屏幕顶部下方约 100 pt，方便和实体菜单栏区分。`--debug-regions` 使用绿色标记渲染轮廓、橙色标记悬停区域、红色标记摄像头排除区。

## 原生点击测试的操作边界

不带 `--preview` 运行 `test-notch-presentation.sh` 时，脚本会编译除正式 `main` 入口外的生产源码，最低部署目标为 macOS 11，并把 PNG 与测试结果写到：

```text
build/notch-island/
```

如果当前会话允许投递系统事件，脚本会启动独立接收进程，并向隔离窗口发送真实 WindowServer 鼠标事件。脚本设计为结束时恢复指针并终止接收进程，但测试期间仍会移动真实鼠标指针。建议：

1. 在隔离的图形会话中运行，不要同时使用鼠标。
2. 不要与其他 AppKit UI 测试并发运行。
3. 结束后确认指针已经恢复，并检查没有遗留预览或测试窗口。
4. 用以下只读命令检查是否还有 harness 或点击接收进程：

```bash
pgrep -fl 'NotchHarness|click-receiver'
```

发现残留时先关闭相关测试窗口和进程，再继续其他图形测试。脚本不会为了获得事件投递权限而弹出授权提示；没有相应权限时，真实点击投递项会明确标为 `NOT RUN`，不能当作通过。

## 验证边界

自动化和合成预览可验证状态转换、布局、轮廓、点击区域与资源约束，但不能替代所有硬件和系统组合。以下场景应作为单独的真机验证：

- 实体刘海边缘贴合和摄像头穿透。
- 全屏应用与菜单栏自动隐藏。
- 多显示器切换、热插拔和睡眠唤醒。
- 菜单栏拥挤环境。
- 真实 Touch Bar 常驻和系统控制条交互。
- macOS 11 运行时。
- 从受支持安装路径完成更新下载、替换、重启和失败恢复的端到端链路。

合成截图和自动化结果不应描述为实体刘海、完整自动更新或所有系统版本已经验收。当前版本的具体构建与发布证据见 [v0.1.30 发布验证记录](RELEASE-0.1.30.md)。

相关文档：

- [使用指南](USER-GUIDE.md)
- [数据与隐私](DATA-AND-PRIVACY.md)
- [更新与恢复](UPDATING.md)
- [原生刘海实现与验证](NotchIsland/README.md)
- [Hooks 实验说明](HOOKS-EXPERIMENT.md)
