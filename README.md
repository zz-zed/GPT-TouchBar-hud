# GPT TouchBar HUD

**在 Mac 上随时查看 ChatGPT / Codex 的账号额度与用量，无需 Touch Bar。**

不用反复切回账户页面：在菜单栏、刘海面板或桌面浮窗中查看剩余额度、重置时间和 Token 用量。配备 Touch Bar 的 Mac，还能在键盘上方显示额度条。

**[下载最新版本](https://github.com/zz-zed/GPT-TouchBar-hud/releases/latest) · [安装说明](#快速开始) · [常见问题](#常见问题) · [反馈问题](https://github.com/zz-zed/GPT-TouchBar-hud/issues)**

提供 Apple Silicon 和 Intel 安装包；不需要填写 API Key。使用前需要安装并登录包含所需本机接口的 ChatGPT / Codex 客户端，具体要求见下文。

## 看看它如何工作

有刘海的 Mac 默认使用 **额度预览态 Peek**，平时直接显示额度与重置时间，点击后展开“额度 / 活动 / 用量”详情。也可以选择 **静止态 Compact**，只保留两侧指示器，悬停时再预览额度。以上默认行为适用于尚未保存相关偏好的用户。

![刘海额度预览态 Peek：默认常驻显示额度与重置时间](Documentation/NotchIsland/evidence/synthetic-peek.png)

*上图由原生渲染代码生成，桌面、摄像头区域和数据均为模拟，不是实体刘海屏照片。*

| 展示方式 | 使用方式 |
| --- | --- |
| 菜单栏 | 查看状态图标或主要额度，点击打开完整摘要和操作菜单。 |
| 刘海面板 | 有有效刘海区域时使用；预览额度，点击展开详情，随时可以隐藏。 |
| 桌面浮窗 | 无刘海时也能使用；按需打开，以单行显示额度与任务状态。 |
| Touch Bar | 仅对应硬件可用；可跨 App 常驻额度条，右侧保留系统控制条。 |

<details>
<summary>查看展开详情、菜单栏和桌面浮窗</summary>

**刘海展开详情**

![刘海展开详情原生模拟](Documentation/NotchIsland/evidence/refined-synthetic-expanded.png)

**菜单栏摘要**

![菜单栏原生摘要](Marketing/readme-native-menu-summary.png)

**桌面浮窗**

![桌面浮窗原生排版](Marketing/readme-native-quiet.png)

这些图片使用演示数据；原生视图渲染不等同于真实桌面录屏或实体设备照片。更多界面和交互说明见[使用指南](Documentation/USER-GUIDE.md)。

</details>

## 快速开始

### 1. 安装前确认

ChatGPT、Codex 或 GPT 客户端需要安装在系统的 `/Applications` 目录，并已完成登录。应用依赖客户端随附的本机 `codex app-server`；仅在浏览器中登录不满足使用条件，也不是安装任意版本的同名客户端就一定可用。

本工具的**最低构建目标为 macOS 11.0**，不等于已完成所有系统版本的运行验证。Intel 安装包也不代表所有宿主客户端都支持 Intel；还需满足所用客户端及其内置运行程序的要求。当前验证边界见[兼容性与已知限制](#兼容性与已知限制)。

在“苹果菜单 → 关于本机”查看芯片或处理器，再选择安装包；是否有 Touch Bar 不影响安装包选择。

| 你的 Mac | 下载文件 |
| --- | --- |
| Apple 芯片（M 系列） | `GPT-TouchBar-HUD-<版本号>-arm64.dmg` |
| Intel 处理器 | `GPT-TouchBar-HUD-<版本号>-x86_64.dmg` |

### 2. 下载安装

1. 打开[最新正式版本](https://github.com/zz-zed/GPT-TouchBar-hud/releases/latest)，在 Assets 中下载对应的 `.dmg`，不是源码压缩包。
2. 打开 DMG，将 `GPT TouchBar HUD.app` 拖入 `Applications`。
3. 先启动并登录 ChatGPT / Codex 客户端，再打开 `GPT TouchBar HUD.app`。

**首次打开提示“无法验证开发者”？** 当前安装包采用 ad-hoc 签名，尚未经过 Apple 公证。仅对你信任的本仓库安装包，可使用 DMG 中的 `首次打开助手.command`，输入 `OPEN` 并按回车；若助手也无法打开，可先尝试打开应用，再到系统“隐私与安全性”中查找“仍要打开”。较旧系统的入口名称可能不同。

无需开启“任何来源”或关闭系统安全保护。若系统提示恶意软件或应用损坏，请停止操作，重新下载或[反馈问题](https://github.com/zz-zed/GPT-TouchBar-hud/issues)。

### 3. 打开后，你应该看到什么？

应用运行在**菜单栏**，不会在 Dock 常驻。首次使用且尚未保存相关设置时：

| 屏幕或硬件 | 默认表现 |
| --- | --- |
| 有有效刘海区域 | 显示刘海面板，以 Peek 常驻预览额度。 |
| 没有有效刘海区域 | 桌面浮窗默认隐藏；可从菜单栏选择“显示状态面板”。 |
| 配备 Touch Bar 且接口可用 | 默认开启 Touch Bar 常驻额度条。 |

菜单栏内容默认为“自动”：**面板显示时只保留状态图标，面板隐藏后显示一项主要额度**。所以，菜单栏只有图标并不代表额度读取失败。

首次运行后会注册当前用户的自动启动项。之后 ChatGPT / Codex 启动时，本工具会随之启动；宿主完全退出后，本工具也会退出。在菜单栏手动退出本工具后，本轮宿主会话内不会再次自动拉起。

**升级保留已有设置。** 已选 Compact、隐藏面板或手动指定展示方式的用户，不会因升级被强制改为 Peek 或重新显示面板。

## 常用操作

| 你想做什么 | 操作入口 |
| --- | --- |
| 查看完整额度、重置时间与用量 | 点击菜单栏图标，或点击刘海面板展开详情。 |
| 显示或隐藏状态面板 | 菜单栏 → 显示状态面板 / 隐藏状态面板。 |
| 切换刘海面板与桌面浮窗 | 菜单栏 → 显示形式 → 自动 / 刘海融合 / 桌面浮窗。 |
| 让刘海平时也显示额度 | 设置 → 通用 → 刘海常驻形态 → 额度预览态 Peek。 |
| 让刘海仅在悬停时预览额度 | 设置 → 通用 → 刘海常驻形态 → 静止态 Compact。 |
| 让菜单栏一直显示额度 | 菜单栏内容 → 单额度或完整额度，不使用“自动”。 |
| 刷新数据或调整设置 | 菜单栏 → 刷新额度 / 设置…；设置快捷键为 `⌘,`。 |
| 关闭任务监测或 Touch Bar 常驻 | 分别在设置 → 通用、设置 → Touch Bar 中关闭。 |
| 查看新版本 | 菜单栏 → 检查更新…，或设置 → 更新。 |

自动检查更新默认开启，**只提示，不自动下载安装**；点击“安装并重启”后才下载、校验和安装。可以在设置中关闭自动检查。详见[更新与恢复](Documentation/UPDATING.md)。

完整的设置、交互和启动规则见[使用指南](Documentation/USER-GUIDE.md)。

## 能看到哪些数据？

| 信息 | 展示范围 |
| --- | --- |
| 额度、重置与点数 | 按账号实际返回显示 5 小时 / 周额度、重置时间、完整重置次数、最早到期时间及点数余额；不同账号可能显示不同项目。 |
| 昨日与累计 Token | 来自客户端返回的账号统计，不是扫描当前电脑的会话日志后累加。 |
| 任务状态（实验性） | 推断本机 Codex 任务的执行中、最近完成或未知状态，不代表网页、远程或全部账号任务。 |

**任务状态默认开启，可以关闭。** “最近完成”只表示本轮执行结束，不等于整个目标完成；当前不识别等待审批、等待输入或失败，也不提供进度百分比。额度和 Token 读取不依赖任务监测。

Hooks 是另一项**默认关闭**的任务监测实验，普通使用无需启用。它需要审阅并应用配置，关闭实验不等于清理已写入的配置和 helper。详见[Hooks 实验说明](Documentation/HOOKS-EXPERIMENT.md)。

## 常见问题

<details>
<summary>没有 Touch Bar，或者没有刘海，还能用吗？</summary>

可以。菜单栏不依赖这两种硬件；没有有效刘海区域时可以使用桌面浮窗。Touch Bar 只是对应机型上的额外展示方式。

</details>

<details>
<summary>打开后没有窗口，或菜单栏只有图标，是不是没启动？</summary>

先查看菜单栏。应用不在 Dock 常驻，无刘海时桌面浮窗默认隐藏；从菜单栏选择“显示状态面板”即可打开。菜单栏“自动”模式会在面板显示时只保留图标，需要常显额度可改为“单额度”或“完整额度”。再次双击已运行的应用也可打开设置。

</details>

<details>
<summary>为什么额度一直是 --，或者只有周额度？</summary>

`--` 表示数据缺失或无法确认，不等于额度为 0。先确认客户端已登录、安装在 `/Applications`，再从菜单栏刷新；持续无数据时，检查客户端内置接口是否可用，见[数据来源与排查](Documentation/DATA-AND-PRIVACY.md#额度与用量读取排查)。

只有周额度不一定是异常：应用只显示账号实际提供的窗口，不会补出不存在的 5 小时额度。点数余额为 0、无限额度或字段缺失时不显示。

</details>

<details>
<summary>Token 后面的 *、任务状态的 ? 分别是什么意思？</summary>

Token 后的 `*` 表示刷新失败后保留的上次成功数据，不是实时结果。任务 `?` 表示无法可靠确认状态，不能理解为任务已结束或失败。日志缺失、格式变化或长时间没有新记录都可能导致未知；可关闭任务状态显示，不影响额度与 Token 读取。

</details>

<details>
<summary>升级后为什么仍然是 Compact，或者面板没有显示？</summary>

升级保留已有选择。只有尚未保存常驻形态偏好时才默认使用 Peek；已经选择 Compact 或隐藏面板的用户维持原设置。需要调整时，修改“刘海常驻形态”，并确认面板没有被隐藏。

</details>

<details>
<summary>刘海显示不合适，或者 Touch Bar 原来的快捷按钮不见了？</summary>

刘海显示、全屏或多屏切换出现问题时，可先将“显示形式”切换为“桌面浮窗”。

Touch Bar 常驻会占用左侧应用区域，覆盖其他 App 的对应快捷按钮；关闭“Touch Bar 常驻”即可释放。右侧仍使用 macOS 系统控制条。

</details>

<details>
<summary>为什么切换 English 后，设置界面还是中文？</summary>

当前语言选项只影响额度与任务信息，导航和设置仍为中文。中文用量使用“万 / 亿”，英文使用 K / M / B / T。

</details>

<details>
<summary>如何停止自动启动或完整卸载？</summary>

临时停用可从菜单栏退出，本轮宿主会话内不会再次自动启动。卸载应用时还需清理自动启动项；启用过 Hooks 时，应在删除 App 前先清理配置，再审阅 helper 等残留文件。按[卸载与清理](Documentation/UNINSTALL.md)操作，不要直接删除整个 Codex 配置目录。

</details>

其他问题请[提交 Issue](https://github.com/zz-zed/GPT-TouchBar-hud/issues)，注明应用版本、macOS 版本、芯片类型、所用客户端及版本、是否使用刘海或 Touch Bar，以及复现步骤。截图或日志请先移除账号信息、对话内容和其他隐私数据。

## 隐私与联网

本工具不要求 API Key，也不保存密码、授权码或访问令牌。额度和 Token 由本机客户端组件使用已有登录态向服务端读取，**不是完全离线工具**。

任务监测默认只读本机 Codex 的任务索引和近期日志片段，不展示、另存或上传对话正文；关闭任务状态显示后停止任务日志读取。自动更新检查会访问本仓库的 GitHub Release，不携带账号信息或任务内容。

界面偏好、启动状态、更新记录，以及启用 Hooks 后的配置和生命周期缓存会保存在本机。写入位置、读取边界和清理方式见[数据与隐私说明](Documentation/DATA-AND-PRIVACY.md)。

## 兼容性与已知限制

安装包尚未经过 Apple Developer 签名和公证。客户端升级可能改变数据接口或日志格式，导致需要适配；拥有安装包并不等于所有客户端与系统组合都已验证。

刘海面板可能占用菜单栏空间；实体刘海接缝、全屏、自动隐藏菜单栏、多屏和睡眠恢复仍有真机验收边界。macOS 11 或没有有效刘海几何时回退桌面浮窗。Touch Bar 常驻依赖系统私有接口，系统更新后可能不可用；此时保留普通焦点绑定模式。

[v0.1.30 发布验证记录](Documentation/RELEASE-0.1.30.md)已记录双架构构建与安装包检查，但实际 macOS 11 运行和正式安装路径中的自动更新完整链路仍未完成验收。Hooks 的真实宿主执行、任务准确性、延迟和长期能耗也尚未形成验收结论。

## 更多文档

[使用指南](Documentation/USER-GUIDE.md) · [数据与隐私](Documentation/DATA-AND-PRIVACY.md) · [更新与恢复](Documentation/UPDATING.md) · [卸载与清理](Documentation/UNINSTALL.md) · [从源码构建与测试](Documentation/DEVELOPMENT.md)

高级功能与实现：[Hooks 实验](Documentation/HOOKS-EXPERIMENT.md) · [原生刘海面板与验证](Documentation/NotchIsland/README.md)。

## 贡献与许可证

欢迎提交 Bug 修复、兼容性改进、功能优化、测试与文档类 Pull Request，开始前请阅读[贡献指南](CONTRIBUTING.md)。

本项目使用 [MIT License](LICENSE)。感谢 [jackchensky/TouchBarCodexToken](https://github.com/jackchensky/TouchBarCodexToken) 提供的基础实现。
