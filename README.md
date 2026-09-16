# TouchBarCodexToken

在 Mac 的 Touch Bar、菜单栏和可选桌面浮窗中，持续查看 ChatGPT / Codex 的额度与 Token 使用情况。

![TouchBarCodexToken 宣传图](Marketing/promo-style-d-tech-board.png)

## 这是什么

TouchBarCodexToken 是一个轻量的 macOS 状态工具。它读取 ChatGPT / Codex 自带的本机 `codex app-server`，把以下信息整理成随时可见的状态：

- 5 小时额度、周额度及各自的重置时间。
- 可用完整重置次数及最早到期日期。
- 额度点数余额。
- GPT 账号昨日 Token 和累计 Token。

应用默认把完整额度条常驻在 Touch Bar 左侧应用区域。Mac 没有 Touch Bar 时，菜单栏和桌面 HUD 仍可正常使用。

它适合希望在工作过程中快速确认剩余额度、不想频繁打开账号页面，也不希望额外配置 API Key 的 ChatGPT / Codex 用户。

## 项目来源与致谢

本仓库基于 [jackchensky/TouchBarCodexToken](https://github.com/jackchensky/TouchBarCodexToken) 继续迭代。原项目提供了 Swift / AppKit 应用基础、菜单栏与 HUD 展示、Touch Bar 支持、本机 app-server 接入和自动启动能力；当前版本在此基础上增加了跨 App 常驻 Touch Bar、服务端 Token 统计、布局与性能优化、系统控制条共存，以及双架构自动打包。

原项目 README 所列作者信息：

- 个人博客：[jackchen.cn](https://jackchen.cn)
- 小红书：Jackchen

当前迭代仓库：[zz-zed/TouchBarCodexToken](https://github.com/zz-zed/TouchBarCodexToken)

## 主要功能

| 功能 | 说明 |
| --- | --- |
| Touch Bar 常驻 | 默认在左侧应用区域显示完整额度条，切换到其他 App 后仍可见；可在设置中关闭。 |
| 系统控制条共存 | 右侧继续使用 macOS 原有的亮度、音量等控制项；控制条展开时隐藏 Token，收起后恢复。 |
| 多种额度展示 | 根据接口实际返回显示 5 小时额度、周额度、重置次数、到期时间和点数余额，不重复伪造不存在的额度窗口。 |
| 账号 Token 统计 | 显示 GPT 账号“昨日”和“累计”Token，使用服务端账号口径，不再扫描本地会话日志作为主数据。 |
| 菜单栏状态 | 直接显示主要额度，点击后可刷新、控制 HUD、调整外观或退出。 |
| 可选桌面 HUD | 启动时默认隐藏；需要时可从菜单栏显示，并自定义颜色、背景透明度和文字透明度。 |
| 自动联动宿主 | 首次运行后注册 LaunchAgent；ChatGPT / Codex 启动时自动运行，宿主完全退出后自动结束。 |
| 刷新与容错 | 额度定时刷新；短暂失败时保留上次数据，Token 旧数据用 `*` 标记，缺失数据用 `--` 显示。 |
| 本地登录态 | 不要求填写 API Key，不抓取网页，不保存密码、授权码或访问令牌。 |
| 双架构安装包 | GitHub Release 自动构建 Apple Silicon 与 Intel 两个 DMG，并附带 SHA-256 校验文件。 |

Touch Bar 显示效果：

![Touch Bar 清晰细节](Marketing/promo-touchbar-upgrade-detail.png)

## 工作原理

```text
ChatGPT / Codex 的本机登录态
              │
              ▼
       codex app-server
              │
   ┌──────────┴──────────┐
   │                     │
account/rateLimits/read  account/usage/read
   │                     │
   └──────────┬──────────┘
              ▼
     TouchBarCodexToken
       ├─ Touch Bar
       ├─ macOS 菜单栏
       └─ 桌面 HUD（可选）
```

应用会依次查找以下本机程序：

```text
/Applications/ChatGPT.app/Contents/Resources/codex
/Applications/Codex.app/Contents/Resources/codex
/Applications/GPT.app/Contents/Resources/codex
```

找到后以子进程方式启动 `codex app-server --listen stdio://`，通过 JSON-RPC 读取额度和账号 Token 数据。应用本身不直接处理登录凭据。

## 快速开始

### 1. 环境要求

- macOS 11 Big Sur 或更新版本。
- 已将 ChatGPT、Codex 或 GPT 安装在系统 `/Applications` 目录。
- 已在宿主应用中登录，并且其本机 `codex app-server` 可用。

| Mac | 安装包 | 可用界面 |
| --- | --- | --- |
| Apple Silicon（M1 / M2 / M3 / M4 等） | 文件名以 `arm64.dmg` 结尾 | Touch Bar（如有）、菜单栏、HUD |
| Intel Mac | 文件名以 `x86_64.dmg` 结尾 | Touch Bar（如有）、菜单栏、HUD |
| 没有 Touch Bar 的 Mac | 选择与处理器一致的 DMG | 菜单栏、HUD |

### 2. 下载安装

1. 打开当前仓库的 [Releases](https://github.com/zz-zed/TouchBarCodexToken/releases) 页面。
2. 根据 Mac 处理器下载 `arm64.dmg` 或 `x86_64.dmg`。
3. 打开 DMG，把 `TouchBarCodexToken.app` 拖入 `Applications`。
4. 先启动并登录 ChatGPT / Codex，再打开 `TouchBarCodexToken.app`。

当前安装包没有 Apple Developer 证书签名和公证。首次打开若 macOS 提示无法验证开发者，请在 Finder 中右键点击应用，选择“打开”，然后再次确认。不要关闭系统整体安全保护。

### 3. 首次运行

首次从 `Applications` 启动后，应用会：

- 在菜单栏显示额度状态。
- 默认启用 Touch Bar 常驻。
- 默认隐藏桌面 HUD，避免启动时遮挡内容。
- 注册当前用户的 LaunchAgent：

```text
~/Library/LaunchAgents/com.jackchen.TouchBarCodexToken.CodexLauncher.plist
```

之后 ChatGPT / Codex 启动时，LaunchAgent 会自动打开额度工具。若你在宿主仍运行时手动退出，本轮宿主会话内不会再次自动拉起；宿主完全退出后会解除这次手动退出状态。

## 日常使用

### Touch Bar

默认开启 `设置 → Touch Bar 常驻`：

- 额度条位于左侧应用区域，右侧保留系统控制条。
- 切换到其他 App 后，额度条会重新呈现。
- 展开系统控制条时，Token 展示会被系统覆盖；收起后自动恢复。
- 普通状态不显示额外的关闭按钮，退出应用请使用菜单栏或 HUD 菜单。
- 隐藏 HUD 不影响 Touch Bar 常驻。

关闭 `Touch Bar 常驻` 后，应用会立即释放系统级额度条。此时仍可通过点击已显示的 HUD，使用和当前 App 焦点绑定的普通 Touch Bar 模式。

常驻模式会占用其他 App 的 Touch Bar 应用区域，因此其他 App 原本放在左侧的快捷按钮会被覆盖。需要使用这些按钮时，可暂时关闭常驻开关。

### 菜单栏

菜单栏标题优先显示：

```text
5h 85%  W 80%
```

如果账号没有 5 小时窗口但提供完整重置次数，则显示类似：

```text
重置3  W 96%
```

菜单包含以下操作：

| 菜单项 | 用途 |
| --- | --- |
| 显示浮窗 / 隐藏浮窗 | 控制桌面 HUD。 |
| 刷新额度 | 立即刷新额度，并在防抖允许时刷新 Token 统计。 |
| Touch Bar 常驻 | 开启或关闭跨 App 常驻。 |
| 浮窗颜色 | 选择深黑、石墨、深蓝、深绿或紫色。 |
| 背景透明度 | 单独调整 HUD 胶囊背景透明度。 |
| 文字透明度 | 调整 HUD 文字、状态点和操作图标透明度。 |
| 退出 | 结束应用，并在当前宿主会话内阻止自动重新拉起。 |

### 桌面 HUD

HUD 需要从菜单栏手动显示，常见状态如下：

```text
● 5h 85%   ● 7d 80%   ↻   ×
```

```text
● 重置 3次   ● 7d 96%   ↻   ×
```

- `↻`：刷新数据。
- `×`：退出应用。
- 绿色、黄色和红色状态点表示剩余额度从充足到较低。
- 鼠标悬停可查看更新时间、Token 统计和错误说明。
- 右键点击 HUD 可打开与菜单栏一致的设置和操作菜单。

## 数据说明

| 指标 | 数据来源与口径 |
| --- | --- |
| 5 小时 / 周额度 | `account/rateLimits/read` 返回的额度窗口；按窗口时长识别，不把单个周窗口重复显示成 5 小时额度。 |
| 重置次数 | `rateLimitResetCredits` 中当前可用的完整重置次数及最早到期时间。 |
| 点数余额 | 额度快照中的 `credits.balance`；余额为 0、无限额度或字段缺失时不显示。 |
| 昨日 Token | `account/usage/read` 的昨日每日桶，使用当前系统日历匹配日期。 |
| 累计 Token | `account/usage/read` 返回的账号累计值，不用有限天数的每日桶求和代替。 |

刷新规则：

- 额度通常每 60 秒刷新，也会响应 app-server 的额度更新通知。
- 账号 Token 通常每 5 分钟刷新。
- 手动刷新 Token 的最短间隔为 10 秒，避免连续点击产生过多请求。
- Token 请求失败后按 5、10、20、30 分钟逐步退避；如果有上次成功结果，会继续显示并增加 `*`。
- 缺失或无法确认的数据显示 `--`，不会当成 0。

## 兼容性与已知限制

- Touch Bar 不是必需硬件；无 Touch Bar 的 Mac 仍可使用菜单栏和 HUD。
- 常驻 Touch Bar 使用经过运行时签名检查的 AppKit 私有 system-modal 接口。macOS 的公开 API 只能沿当前 App 的焦点响应链显示 Touch Bar，无法实现跨 App 常驻。
- 私有接口可能在未来 macOS 更新中变化。接口缺失或签名不兼容时，常驻开关会不可用，应用保留普通焦点绑定模式。
- 当前安装包采用 ad-hoc 签名，尚未完成 Apple Developer 签名和公证。
- 账号 Token 日期桶的服务端全局时区规则没有公开承诺；当前实现按本机日历匹配昨日日期。
- 同一邮箱和套餐下的 workspace 切换主要依赖宿主发出的账号变更通知。

## 从源码构建

需要安装 Xcode Command Line Tools 和支持 Swift 5.8 的工具链。

```bash
git clone https://github.com/zz-zed/TouchBarCodexToken.git
cd TouchBarCodexToken
scripts/build-app.sh
open build/TouchBarCodexToken.app
```

`scripts/build-app.sh` 优先使用 SwiftPM Release 构建；如果本机 SwiftPM SDK 探测失败，会尝试使用 `swiftc -sdk` 后备路径。

生成本机架构 DMG：

```bash
scripts/package-dmg.sh
```

输出位置：

```text
dist/TouchBarCodexToken-<版本号>.dmg
```

运行回归检查：

```bash
bash scripts/test-account-token-usage.sh
bash scripts/test-token-usage.sh
bash scripts/test-touchbar-layout.sh
bash scripts/test-touchbar.sh
```

其中真实 system-modal 冒烟检查需要图形会话和兼容系统，会短暂呈现 Touch Bar：

```bash
bash scripts/test-touchbar.sh --smoke-system
```

## GitHub Release 自动打包

工作流位于 `.github/workflows/build-dmg.yml`。

- `main` 推送和 Pull Request：分别构建 arm64、x86_64 DMG，并保存为 Actions Artifact，用于验证代码可以在两种架构打包。
- GitHub Release 发布：从 Release 对应 Tag 构建两个安装包，生成 `SHA256SUMS.txt`，并自动上传到该 Release。
- Release Tag 必须与 `Resources/Info.plist` 的版本一致。例如应用版本 `0.1.20` 对应 Tag `v0.1.20`，不一致时工作流会失败。
- 工作流不会自动创建 Tag 或 Release；只有发布 Release 后才会上传正式安装包。

## 当前版本

### 0.1.20 · 2026-09-16

- 完成 Touch Bar 跨 App 常驻，并增加持久化开关。
- 保留右侧系统控制条，系统控制条展开时隐藏 Token、收起后恢复。
- 修复普通状态出现系统关闭按钮的问题。
- Touch Bar 改用 ChatGPT 图标并优化左对齐、文字宽度和余额布局。
- 启动时默认隐藏 HUD。
- 昨日与累计 Token 改为账号服务端口径。
- 优化 Token 读取与刷新策略，避免高 CPU 占用。
- 增加双架构 DMG 自动构建与 GitHub Release 附件上传。

完整开发记录和验证状态见 [PROJECT_STATUS.md](PROJECT_STATUS.md)，更早版本变更可查阅 [提交历史](https://github.com/zz-zed/TouchBarCodexToken/commits/main/)。

## 隐私说明

TouchBarCodexToken 不保存密码、API Key、授权码或访问令牌，也不会上传本机会话日志。

额度和 Token 数据通过本机 `codex app-server` 获取。app-server 使用 ChatGPT / Codex 已有登录态访问服务端；本应用只在内存中保留当前展示数据和用于识别账号变化的元数据。磁盘上仅保存正常运行所需的应用设置、LaunchAgent 和手动退出状态。

## 许可证

本项目遵循 [MIT License](LICENSE)。感谢 [jackchensky/TouchBarCodexToken](https://github.com/jackchensky/TouchBarCodexToken) 原项目提供的基础实现。
