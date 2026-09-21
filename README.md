# GPT TouchBar HUD

**在 Mac 上随时查看 ChatGPT / Codex 的账号额度与用量，无需 Touch Bar。**

不用反复切回账户页面：在菜单栏、刘海面板或桌面浮窗中查看剩余额度、重置时间和 Token 用量。配备 Touch Bar 的 Mac，还能在键盘上方显示额度条。

**[下载最新版本](https://github.com/zz-zed/GPT-TouchBar-hud/releases/latest) · [安装说明](#安装与首次运行) · [常见问题](#常见问题) · [反馈问题](https://github.com/zz-zed/GPT-TouchBar-hud/issues)**

提供 Apple Silicon 和 Intel 安装包。使用前需要安装并登录受支持的本机客户端。可选的任务状态提示只针对本机 Codex 任务，不代表全部 ChatGPT 会话。

## 看看效果

有有效刘海区域的屏幕，首次使用默认以 **额度预览态 Peek** 显示额度与重置时间，点击后展开详情。也可选择更简洁的 **静止态 Compact**，悬停时再查看额度。

![默认 Peek：刘海两侧展示额度与重置时间](Documentation/NotchIsland/evidence/synthetic-peek.png)

这是正式原生渲染代码生成的模拟画面；桌面、摄像头和数据均为演示，不是实体刘海屏照片。

| 展示方式 | 适合怎样使用 |
| --- | --- |
| 菜单栏 | 查看图标或额度，点击查看完整摘要与操作；所有支持的 Mac 均可使用。 |
| 刘海融合 | 在顶部预览额度，点击展开“额度 / 活动 / 用量”；需要有效刘海区域。 |
| 桌面浮窗 | 用单行面板持续查看任务与额度，可按需显示或隐藏。 |
| Touch Bar | 在键盘上方常驻额度条；仅限配备 Touch Bar 的机型。 |

<details>
<summary>更多界面：展开详情、精简状态、桌面浮窗与 Touch Bar</summary>

**点击后展开详情**

![刘海详情](Documentation/NotchIsland/evidence/refined-synthetic-expanded.png)

**可选的静止态 Compact**

![刘海精简状态](Documentation/NotchIsland/evidence/synthetic-compact.png)

**桌面浮窗**

![任务与双额度的单行浮窗](Marketing/readme-native-quiet.png)

**菜单栏详情**

![额度、重置时间与用量摘要](Marketing/readme-native-menu-summary.png)

**Touch Bar**

![重置卡、周额度与点数](Marketing/readme-native-balanced-reset-alignment.png)

以上均为原生视图的演示数据截图，不是实体设备照片。更多交互与设置见[使用指南](Documentation/USER-GUIDE.md)。

</details>

## 安装与首次运行

### 安装前确认

- 已将 ChatGPT、Codex 或 GPT 客户端安装在系统 `/Applications` 目录，并完成登录。应用需要客户端内置的 `codex app-server` 可用。
- 安装包的最低构建目标为 **macOS 11**；实际 macOS 11 运行尚未验收，宿主客户端还可能有更高的系统要求。双架构发布 CI 通过不等于所有机型均已实测，详情见[发布验证记录](Documentation/RELEASE-0.1.30.md)。
- 当前安装包使用 ad-hoc 签名，**尚未经过 Apple 公证**，首次打开可能出现安全提示。

安装包只按处理器选择，与是否有 Touch Bar 无关。在“ → 关于本机”查看芯片或处理器：

| 你的 Mac | 下载文件 |
| --- | --- |
| Apple 芯片 | `GPT-TouchBar-HUD-<版本号>-arm64.dmg` |
| Intel 处理器 | `GPT-TouchBar-HUD-<版本号>-x86_64.dmg` |

### 安装步骤

1. 从[最新 Release](https://github.com/zz-zed/GPT-TouchBar-hud/releases/latest) 下载对应 DMG。
2. 打开 DMG，把 `GPT TouchBar HUD.app` 拖入 `Applications`。
3. 先启动并登录 ChatGPT / Codex，再打开 `GPT TouchBar HUD.app`。
4. 如提示“无法验证开发者”，双击安装包中的 `首次打开助手.command`，输入 `OPEN` 后回车。也可先尝试打开应用，再到“系统设置 → 隐私与安全性 → 仍要打开”。

首次打开助手仅用于你信任的安装包，无需开启“任何来源”。如果系统提示恶意软件或应用损坏，请先停止，重新下载或[反馈问题](https://github.com/zz-zed/GPT-TouchBar-hud/issues)。

### 打开后，你应该看到什么

- **菜单栏有状态图标，Dock 不常驻图标。**应用没有必须一直打开的主窗口。
- **有刘海**：首次使用且没有历史设置时，显示 Peek 额度预览；点击面板展开详情。
- **没有刘海**：桌面浮窗默认隐藏，从菜单栏选择“显示状态面板”即可打开。
- **菜单栏只有图标也可能是正常的。**“菜单栏内容”为“自动”时，状态面板显示期间只留图标，面板隐藏后显示一项主要额度。
- **升级会保留已有选择。**已选择 Compact 或隐藏面板的用户，不会被强制切换为 Peek 或重新显示面板。

应用会注册当前用户的自动启动项，随 ChatGPT / Codex 启动，并在宿主完全退出后结束。通过菜单“退出”后，本轮宿主会话内不会自动重新拉起；宿主完全退出再启动后恢复联动。移除自动启动项见[卸载说明](Documentation/UNINSTALL.md)。

## 常用操作

| 你想做什么 | 去哪里操作 |
| --- | --- |
| 查看完整额度、Token 与点数 | 点击菜单栏图标，或点击刘海面板展开详情。 |
| 显示或隐藏当前面板 | 菜单栏 → “显示状态面板 / 隐藏状态面板”。 |
| 让刘海平时也显示额度 | 设置 → 通用 → 刘海常驻形态 → “额度预览态 Peek（默认）”。 |
| 平时只保留刘海两侧指示器 | 设置 → 通用 → 刘海常驻形态 → “静止态 Compact”。 |
| 让菜单栏一直显示额度 | 将“菜单栏内容”从“自动”改为“单额度”或“完整额度”。 |
| 改用桌面浮窗 | 设置 → 通用 → 显示模式 → “桌面浮窗”。 |
| 调整浮窗颜色与透明度 | 设置 → 外观；这些选项不改变刘海面板的黑色外观。 |
| 关闭任务状态监测 | 设置 → 通用 → 关闭“显示任务状态（实验性）”。 |
| 恢复其他 App 的 Touch Bar 按钮 | 设置 → Touch Bar → 关闭“Touch Bar 常驻”。 |
| 检查或安装新版本 | 菜单栏 → “检查更新…”或设置 → 更新。 |

自动检查更新默认开启，只提示新版本，**不会自动下载或安装**。你确认“安装并重启”后才会下载安装；可在设置中关闭自动检查。安装路径要求与失败恢复见[更新说明](Documentation/UPDATING.md)。

## 数据与功能范围

| 信息 | 覆盖范围 |
| --- | --- |
| 额度、重置时间、重置次数与点数 | 按客户端接口实际返回显示，不同账号可能提供不同项目。 |
| 昨日与累计 Token | 客户端返回的账号统计，不是对当前电脑的会话日志求和。 |
| 任务状态 | 本机 Codex 任务的实验性提示，不覆盖全部网页、远程或账号任务。 |

任务状态提示**默认开启**，会有界读取本机任务索引和近期日志，可能显示执行中、最近完成或未知。它不表示整个目标已完成，也不提供准确进度百分比；关闭开关后停止任务日志读取。

Hooks 监测实验**默认关闭**。启用需要审阅配置并在宿主中正常信任；它仍使用本机索引和日志核对状态，连接正常不代表覆盖全部任务。详见[数据与隐私](Documentation/DATA-AND-PRIVACY.md)和[Hooks 实验说明](Documentation/HOOKS-EXPERIMENT.md)。

## 常见问题

<details>
<summary>打开后没有窗口，是不是没启动？</summary>

先查看菜单栏图标。应用不在 Dock 常驻，无刘海时桌面浮窗默认隐藏；点击菜单栏中的“显示状态面板”。已保存的隐藏状态会跨重启保留，再次打开正在运行的应用可进入设置。

</details>

<details>
<summary>为什么菜单栏只有图标，没有额度？</summary>

“自动”模式下，面板显示期间仅保留图标。需要常显额度时，将“菜单栏内容”改为“单额度”或“完整额度”。

</details>

<details>
<summary>为什么只有周额度，或一直显示 --？</summary>

应用只展示账号实际提供的额度窗口，只有周额度不一定是异常。`--` 表示数据缺失或暂时无法确认；先确认宿主已登录并正常运行，再使用“刷新额度”。仍无数据时，按[数据排查说明](Documentation/DATA-AND-PRIVACY.md)检查客户端与接口，不要在 Issue 中附上登录凭据或完整会话日志。

</details>

<details>
<summary>Token 后的 *、任务状态的 ? 是什么意思？</summary>

Token 后的 `*` 表示刷新失败后保留的旧数据；任务 `?` 表示日志证据或覆盖范围不足，不能确定当前状态。它们不代表零用量、零任务或任务已完成。任务状态不准确时，可以关闭实验性提示。

</details>

<details>
<summary>为什么升级到新版本后仍是 Compact？</summary>

升级保留已有偏好。曾关闭旧版“刘海始终显示额度”的用户仍使用 Compact；从未保存过这项偏好时才默认 Peek。需要更改时，到“设置 → 通用 → 刘海常驻形态”选择 Peek。

</details>

<details>
<summary>为什么选择 English 后，设置仍是中文？</summary>

信息语言仅影响额度与任务信息的文字、日期和数字单位；导航和设置保持中文。

</details>

<details>
<summary>首次打开受阻，或者想完整卸载怎么办？</summary>

首次打开按上方[安装步骤](#安装步骤)操作。卸载时需先处理自动启动项；启用过 Hooks 的用户还需清理本工具配置和 helper。删除 App 不会自动删除这些内容，具体步骤见[卸载说明](Documentation/UNINSTALL.md)。

</details>

## 隐私与兼容性

- 无需配置 API Key，不保存密码或访问令牌，不上传本机会话日志。账号数据通过宿主已有登录态获取；自动检查更新会访问 GitHub。
- 本地会保存偏好、更新状态和自动启动标记；启用 Hooks 或确认安装更新后还会产生相应配置、缓存或恢复材料，详见[数据与隐私](Documentation/DATA-AND-PRIVACY.md)。
- Touch Bar 常驻使用 AppKit 私有接口，可能受系统升级影响，并会占用其他 App 的左侧 Touch Bar 快捷按钮区域；需要时可关闭，右侧系统控制条仍保留。
- 实体刘海接缝、全屏、多屏和唤醒仍需真机验收；实际 macOS 11 运行与正式安装路径中的自动更新完整链路尚未完成验收。遇到刘海适配问题，可改用桌面浮窗。

## 更多文档

| 文档 | 内容 |
| --- | --- |
| [使用指南](Documentation/USER-GUIDE.md) | 菜单栏、刘海、桌面浮窗、Touch Bar 与详细设置。 |
| [数据与隐私](Documentation/DATA-AND-PRIVACY.md) | 数据来源、刷新规则、任务范围、本地存储与排查。 |
| [更新说明](Documentation/UPDATING.md) | 自动检查、安装校验、路径要求与失败恢复。 |
| [卸载说明](Documentation/UNINSTALL.md) | 自动启动项、Hooks、偏好及恢复材料的清理。 |
| [开发说明](Documentation/DEVELOPMENT.md) | 工作原理、源码构建、测试与原生预览。 |
| [Hooks 实验](Documentation/HOOKS-EXPERIMENT.md) | 配置审阅、覆盖范围与清理边界。 |
| [发布记录](https://github.com/zz-zed/GPT-TouchBar-hud/releases) | 正式安装包、变更说明与校验文件。 |

## 贡献与许可证

欢迎反馈问题或提交 Pull Request，开发前请阅读[贡献指南](CONTRIBUTING.md)。反馈时说明应用与 macOS 版本、处理器和复现步骤，勿提交账号凭据或完整会话内容。

本项目遵循 [MIT License](LICENSE)。感谢 [jackchensky/TouchBarCodexToken](https://github.com/jackchensky/TouchBarCodexToken) 原项目提供的基础实现。
