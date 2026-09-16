# TouchBarCodexToken

TouchBarCodexToken 是一个 macOS 菜单栏 + 桌面 HUD 小工具，用本机 Codex app-server 读取 Codex 额度，并把额度窗口或可用重置次数显示在桌面小浮窗和 Touch Bar 上。

![TouchBarCodexToken 宣传图](Marketing/promo-style-d-tech-board.png)

Touch Bar 清晰细节：

![Touch Bar 清晰细节](Marketing/promo-touchbar-upgrade-detail.png)

它不抓网页，也不需要你填写 API Key。应用会自动查找 ChatGPT 合并版或旧版 Codex 中的本机 `codex`：

```bash
/Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
# 或旧版
/Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
```

然后通过 JSON-RPC 调用：

```text
account/rateLimits/read
```

## 作者

- 个人博客：[jackchen.cn](https://jackchen.cn)
- 小红书：Jackchen

## 功能

- 桌面置顶小 HUD：动态显示 `5h xx%`、`7d xx%` 或 `重置 x次`，并提供刷新和退出图标。
- 菜单栏状态：根据接口实际返回显示额度窗口；只有周额度时不再重复显示成 5 小时额度。
- Touch Bar：默认在左侧应用区域常驻，右侧保留系统控制条；可在设置中关闭常驻。系统控制条展开时覆盖 Token，收起后恢复。
- 同步状态：菜单栏、HUD 和 Touch Bar 使用同一份额度状态。
- 自动联动 Codex：检测到 ChatGPT 合并版或旧版 Codex 启动后开启额度条，HUD 默认隐藏；宿主应用退出后自动退出。
- 自动拉起：首次运行 app 后会注册本机 LaunchAgent，之后 Codex 启动时自动打开额度条。
- 刷新保护：刷新失败时保留旧数据，不清空已有额度。
- 外观设置：可从菜单栏或 HUD 右键菜单分别修改颜色、背景透明度和文字透明度。
- 本地优先：只调用本机 Codex app-server，不保存账号、密钥或授权码。

## 兼容性

### Mac 机型

| 机型 | 支持情况 | 说明 |
| --- | --- | --- |
| Intel Mac | 支持 | GitHub Release 提供文件名以 `x86_64.dmg` 结尾的安装包，适合 Intel 芯片 Mac，包括 2016-2019 款带 Touch Bar 的 MacBook Pro。 |
| Apple Silicon Mac | 支持 | GitHub Release 提供文件名以 `arm64.dmg` 结尾的原生安装包，适合 M1 / M2 / M3 / M4 系列 Mac。 |
| 无 Touch Bar 的 Mac | 支持 | 桌面 HUD 和菜单栏额度显示可以正常使用，只是不会显示 Touch Bar 额度条。 |

### Touch Bar

Touch Bar 不是必需硬件。

- 有 Touch Bar 的 Mac：可以使用桌面 HUD、菜单栏和 Touch Bar 额度条。
- 没有 Touch Bar 的 Mac：可以正常使用桌面 HUD 和菜单栏，Touch Bar 相关功能会自然不可见。

### 系统和依赖

- macOS 11 Big Sur 或更新版本。
- 已安装 `/Applications/ChatGPT.app`（Codex 合并版）或旧版 `/Applications/Codex.app`。
- 本机 Codex app-server 可用。

## 界面

启动时默认隐藏 HUD；在菜单栏选择“显示浮窗”后，会显示一个位于屏幕上方附近的小胶囊浮窗：

```text
● 5h 85%   ● 7d 80%   ↻   ×
```

如果当前账号只返回周额度，同时拥有可用的完整重置次数，则显示为：

```text
● 重置 3次   ● 7d 96%   ↻   ×
```

如果没有可用重置次数，则只显示周额度并自动收窄浮窗。

- `↻`：刷新额度。
- `×`：退出应用。
- 状态点为绿色、黄色或红色，表示剩余额度充足、偏低或较低。
- 如果读取失败且没有旧数据，状态点会显示红色。
- 鼠标悬停在 HUD 上可以看到当前状态说明。
- 在 HUD 上点击右键，可直接打开隐藏、刷新、颜色、背景透明度、文字透明度和退出菜单。

## Touch Bar

默认开启“Touch Bar 常驻”：宿主 ChatGPT/Codex 运行期间，在左侧应用区域显示额度条，切换到其他 App 后重新呈现。右侧亮度、音量等控制项由系统保留；点击系统展开箭头后 Token 隐藏，收起后恢复。点击桌面 HUD 主体可以重新显示额度条，常驻模式下不主动激活额度条 App。

菜单栏或 HUD 右键菜单 → `设置` → `Touch Bar 常驻` 可以切换，勾选表示开启。选择会保存，下次启动继续生效。

- 开启：占用左侧应用区域，会覆盖其他 App 在该区域的操作按钮，但不再申请覆盖右侧系统控制条；隐藏桌面 HUD 不影响常驻。系统控制条本身需在 macOS 设置中启用，应用不会修改全局系统偏好。
- 关闭：立即释放系统级额度条，之后不随 App 切换自动恢复；点击 HUD 仍可使用原有的焦点绑定显示。
- 额度条应用退出时释放 Touch Bar；休眠和用户会话切换期间暂停，恢复后重新呈现。

Touch Bar 内容包括：

- ChatGPT 图标（优先读取本机 ChatGPT 应用内的 `icon-chatgpt` 资源）。
- `5 小时` 额度分段电量条；窗口不存在时改为显示可用重置次数和最早到期日期。
- `周限额` 分段电量条。
- 剩余百分比。
- 重置时间。
- GPT 账号 Token 统计：`昨日` 和 `累计`，通过本机 app-server 的 `account/usage/read` 获取服务端统计，不再累计本地会话日志。
- 账号 Token 正常每 5 分钟刷新，点击“刷新额度”同时刷新 Token（重复点击至少间隔 10 秒）；额度窗口维持原有刷新周期。
- 缺失统计显示 `--`，旧数据用 `*` 标记；菜单栏图标悬停可查看更新时间和错误原因。请求失败退避 5/10/20/30 分钟，不自动混用本地统计。
- 只有周额度时，第二行单独显示剩余额度点数，例如 `还剩点数：US$147.56`；两种额度窗口都存在时，点数跟随第二行周额度显示。余额为 0 或接口未返回点数时自动隐藏。

技术限制：macOS 的[公开 Touch Bar API](https://developer.apple.com/documentation/appkit/nstouchbar)沿焦点响应链查找内容，无法实现跨 App 常驻。本项目使用运行时检查的私有系统级接口 `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:`，调用方式可参见 [MTMR](https://github.com/Toxblh/MTMR/blob/master/MTMR/TouchBarController.swift)。未来系统更新可能改变该接口；如果显示或撤销接口缺失、签名不匹配，常驻开关会禁用，保留普通 Touch Bar 行为。接口存在不代表机器具备 Touch Bar，也不代表已经通过实体硬件验收。

## 菜单栏和 HUD 右键菜单

点击菜单栏图标，或在桌面 HUD 上点击右键，可以打开原生 macOS 菜单：

- `显示浮窗` / `隐藏浮窗`
- `刷新额度`
- `设置`
  - `Touch Bar 常驻`（勾选开关，默认开启）
  - `浮窗颜色`
    - 深黑
    - 石墨
    - 深蓝
    - 深绿
    - 紫色
  - `背景透明度`
    - 10%
    - 20%
    - 30%
    - 40%
    - 50%
    - 60%
    - 75%
    - 86%
    - 100%
  - `文字透明度`
    - 10%
    - 20%
    - 30%
    - 40%
    - 50%
    - 60%
    - 75%
    - 86%
    - 100%
- `退出`

HUD 右键菜单只显示 `隐藏浮窗`；隐藏后可以从菜单栏重新显示。两处菜单使用同一份颜色和两项透明度状态，选中项会同步显示。

背景透明度只控制胶囊底色；文字透明度同时控制额度文字、状态点、刷新和退出图标。设置会保存到 `UserDefaults`，下次启动继续生效。

## 安装和运行

### 方式一：构建 app

```bash
scripts/build-app.sh
```

构建成功后会生成：

```text
build/TouchBarCodexToken.app
```

双击这个 app，或运行：

```bash
open build/TouchBarCodexToken.app
```

首次运行后，应用会在当前用户的 `~/Library/LaunchAgents` 下注册一个轻量启动器：

```text
com.jackchen.TouchBarCodexToken.CodexLauncher.plist
```

它每 5 秒检查一次 ChatGPT 合并版或旧版 Codex 是否正在运行。如果宿主应用已启动而额度条未运行，就自动打开 `TouchBarCodexToken.app`。如果你在宿主应用仍运行时手动退出额度条，本轮会话内不会被自动拉起；宿主应用完全退出后会清除这个手动退出状态。

### 方式二：打包 DMG

```bash
scripts/package-dmg.sh
```

打包成功后会生成：

```text
dist/TouchBarCodexToken-0.1.6.dmg
```

分享给其他人时，推荐上传这个 DMG 到 GitHub Releases。当前项目没有 Apple Developer 签名和公证，首次打开时 macOS 可能提示无法验证开发者；用户可以在 Finder 中右键点击 app，选择“打开”，再确认一次。

### GitHub Release 自动打包

在 GitHub 发布 `v版本号` Release 后，Actions 会检出该 Release 对应的 Tag，并自动完成：

- 分别在 Apple Silicon 和 Intel runner 上构建、校验 DMG。
- 将 `TouchBarCodexToken-版本号-arm64.dmg` 和 `TouchBarCodexToken-版本号-x86_64.dmg` 上传为 Release Assets。
- 同时上传 `SHA256SUMS.txt` 校验文件。

Release Tag 必须和 `Resources/Info.plist` 中的版本一致，例如应用版本 `0.1.20` 对应 Tag `v0.1.20`；不一致时工作流会直接失败，避免发布错包。普通 `main` 推送和 Pull Request 仍会构建双架构 Artifact 用于验证，但不会创建或修改 GitHub Release。

### 方式三：开发期直接运行

```bash
swift run
```

## 要求

见上方“兼容性”章节。

## 构建说明

项目使用 Swift / AppKit 实现。

常规构建走 SwiftPM：

```bash
swift build -c release
```

如果本机 Command Line Tools 的 SwiftPM SDK 探测失败，`scripts/build-app.sh` 会 fallback 到 `swiftc -sdk` 直接编译。

### 重新生成 App 图标

项目图标源图在 `Resources/AppIcon.png`，macOS 图标文件在 `Resources/AppIcon.icns`。

```bash
scripts/make-app-icon.py
```

脚本会为 Finder 列表视图常用的小尺寸层生成专门的简化图标，并用标准 ICNS 写入器输出，避免小图标被直接缩小或被系统读成杂色噪点。

## 更新记录

### 0.1.20 - 2026-09-16

- 修正 0.1.19 隐藏系统关闭按钮未生效的问题。本机 DFR 旧函数虽保留符号，函数体实际仅为 `ret`，不能再以符号存在判断功能有效。
- 为本应用常驻 Touch Bar 指定高优先级、零宽度的 `escapeKeyReplacementItemIdentifier` 项，阻止后台呈现时 AppKit 自动补入关闭按钮；不替换其他应用或系统展开控制条的按钮。
- 删除失效的 DFR close-box 调用，不新增轮询或系统设置修改。136 项布局/系统按钮配置检查及 23 项控制器检查通过。
- 用户已在 macOS 27.0 实体 Touch Bar 上确认：普通状态下关闭图标消失，系统控制条展开/收起正常。
- GitHub Release 发布后自动构建 arm64、x86_64 两个 DMG，校验架构和版本后上传安装包及 SHA-256 校验文件；`main` 和 Pull Request 继续保留云端构建校验。

### 0.1.19 - 本地开发，2026-09-16

- 移除 Token 视图自带的常驻退出按钮；退出应用仍可使用菜单栏或手动显示的 HUD。
- 动态解析 `DFRSystemModalShowsCloseBoxWhenFrontMost`，在呈现本应用额度条前隐藏 modal 附带的关闭按钮，撤销时恢复。没有修改系统控制条的原生收起按钮或系统偏好。
- 129 项布局检查和 23 项控制器检查通过；但用户实机反馈系统关闭按钮仍未消失。后续确认运行时符号是空实现，此方法已由 0.1.20 取代。

### 0.1.18 - 本地开发，2026-09-16

- 常驻呈现改为 `placement: 0` 的应用区域，保留右侧原生系统控制条；用户已在实体 Touch Bar 上确认展开隐藏 Token、收起恢复。
- 添加尾部弹性空间使内容靠左，整体宽度从 750 点缩到 600 点；保留系统自身的左侧按钮区域。
- Token 文字栏从固定 66 点改为至少 120 点并提高抗压缩优先级，进度条可收窄；有行内美元余额时省去进度装饰，保留额度百分比、日期、Token 和美元数值。
- 每次启动默认隐藏浮窗，通过菜单栏“显示浮窗”手动打开。
- `bash scripts/test-touchbar-layout.sh` 覆盖 128 项 AppKit 布局检查；`bash scripts/test-touchbar.sh` 覆盖 23 项生命周期和配置检查。

### 0.1.17 - 本地开发，2026-09-16

- 将昨日和累计 Token 改为官方 `account/usage/read` 返回的每日桶及累计值；修复本地日志口径与 GPT 个人页面不一致的问题。
- 昨日数值超过 100 万时仍保留一位小数；缺失数据不当成 0。
- 使用现有 app-server 管理登录态，不提取凭据、不直接请求内部网页接口；内存缓存随账号变化通知或账号元数据变化清除。
- 增加 5 分钟刷新、手动刷新防抖、30 秒单次 RPC 超时、失败退避和旧数据标记。
- 回归检查：`bash scripts/test-account-token-usage.sh`；显式联网只读检查：`bash scripts/test-account-token-usage.sh --live`（仅打印统计汇总，不打印账号或凭据）。
- 保留旧本地扫描器及其测试供对照，应用运行路径不再调用它。

### 0.1.16 - 本地开发，2026-09-16

- Touch Bar 左侧改用本机 ChatGPT 图标，移除旧 `icon-codex` 资源优先级；悬停提示同步改为 ChatGPT。
- 常驻模式与普通焦点模式共用该图标，尺寸和间距保持不变。

### 0.1.15 - 本地开发，2026-09-15

- 修复本地 token 统计反复全量解析历史会话引起的高 CPU 占用。
- 缓存每个文件的统计和读取位置；未变化文件不读取正文，追加日志只读取新增字节，截断或替换后重新统计。
- 使用分块字节扫描和复用的日期解析器；token 统计最多每 60 秒触发一次，额度显示仍按原有刷新机制更新。
- 保持昨日 token 和累计 token 的原有计算口径，支持未写完记录及跨日更新。缓存仅驻留内存，不新增会话内容持久化文件。
- `bash scripts/test-token-usage.sh` 覆盖增量读取与统计正确性；固定约 790 MB 日志对照中新旧统计一致，旧版读取 32.1 秒，新版首次 2.2 秒、缓存后 0.015 秒（本机一次对照结果）。

### 0.1.14 - 本地开发，2026-09-15

- 增加独立的系统级 Touch Bar 控制器，切换 App 时重新呈现完整额度条。
- 菜单栏和 HUD 右键菜单的设置中增加“Touch Bar 常驻”开关，默认开启并保存选择。
- 常驻路径不主动抢占键盘焦点；关闭、退出或暂停时撤销系统级显示。
- 增加生命周期、设置保存、后台数据更新和焦点回归检查：`bash scripts/test-touchbar.sh`。
- `bash scripts/test-touchbar.sh --smoke-system` 额外短暂调用本机系统显示/撤销接口，需要图形会话；测试不会注册启动项或读取账号。实体 Touch Bar 跨 App 显示效果仍需验收。

### 0.1.13 - 2026-08-27

- 修复新版 GPT 接管 Touch Bar 后，点击桌面 HUD 无法重新显示额度条的问题。
- 用户点击 HUD 时会显式激活额度条、让浮窗成为 key window，并重新创建 Touch Bar 与 first responder 链。
- 自动启动时仍保持后台运行，不主动抢占 GPT 的键盘输入焦点。

### 0.1.12 - 2026-08-26

- HUD 单个额度区域从 `70px` 加宽到 `76px`，修复 `5h 100%` 和 `7d 100%` 百分号被裁切的问题。
- 双额度 HUD 宽度从 `238px` 调整为 `250px`，单额度 HUD 从 `160px` 调整为 `166px`。
- 保持胶囊高度、操作按钮尺寸和内部间距不变，只增加完整显示最长百分比所需的宽度。

### 0.1.11 - 2026-08-20

- 适配新版 Codex `account/rateLimits/read` 返回的 `credits.balance`，Touch Bar 可显示 `还剩点数：US$XX.XX`。
- 只有周额度时，周额度显示在第一行，剩余点数独立显示在第二行；同时存在 5 小时和周额度时，点数跟随第二行周额度显示。
- 点数为 0、不可用、无限额度或接口未返回余额时自动隐藏，不占用 Touch Bar 空间。
- 修复隐藏的额度行仍占据高度、导致文字和胶囊条相对 Codex 图标整体偏上的问题。

### 0.1.10 - 2026-08-01

- HUD 背景透明度与文字透明度拆分为两个独立设置。
- `背景透明度` 只控制胶囊底色；`文字透明度` 同时控制额度文字、状态点、刷新和退出图标。
- 菜单栏和 HUD 右键菜单同步两组选中状态，并自动迁移旧版统一透明度设置。

### 0.1.9 - 2026-07-31

- 桌面 HUD 新增原生右键菜单，可直接隐藏浮窗、刷新额度、修改颜色和透明度或退出。
- HUD 右键菜单与菜单栏共用同一份外观状态，颜色和透明度勾选会保持同步。
- 右键隐藏 HUD 后，可从菜单栏的 `显示浮窗` 恢复。

### 0.1.8 - 2026-07-30

- HUD 胶囊背景、额度文字、状态点、刷新和退出按钮改为使用统一透明度。
- 修复低透明度下背景已经变淡、前景内容仍保持完全不透明而显得不协调的问题。

### 0.1.7 - 2026-07-29

- HUD 透明度最低支持从 `45%` 放宽到 `10%`。
- 透明度菜单新增 `10% / 20% / 30% / 40% / 50%` 连续档位，并保留原有 `60% / 75% / 86% / 100%`。
- 透明度只影响 HUD 胶囊背景，额度文字、状态点、刷新和退出按钮保持清晰。

### 0.1.6 - 2026-07-18

- 适配只返回周额度的新账号结构，不再把同一份周额度重复显示成 `5h`。
- 没有 5 小时窗口时，HUD、菜单栏和 Touch Bar 动态显示可用完整重置次数。
- 没有可用重置次数时只显示周额度，并自动收窄 HUD。
- 修复 Codex 合并到 ChatGPT 后 Touch Bar 左侧官方图标不显示的问题，优先使用白底 Codex 官方图标。
- Touch Bar 的到期/重置文字、`|` 分隔线和昨日/累计用量改为固定列，上下两行保持对齐。
- HUD 小幅加宽，避免 `5h 100%` 与 `7d 100%` 同时显示时百分号被遮挡。

### 0.1.5 - 2026-07-10

- 兼容 Codex 合并到 ChatGPT 后的新应用名称和安装路径。
- 自动启动器现在可识别 `ChatGPT`、`Codex` 和 `GPT` 进程。
- app-server 会自动从 ChatGPT 合并版或旧版 Codex 中选择可用的本机 `codex`。
- 应用内生命周期监听同步兼容新旧宿主，继续保持宿主启动时拉起、退出时关闭。

### 0.1.4 - 2026-06-16

- README 增加 Intel Mac、Apple Silicon Mac、无 Touch Bar Mac 的兼容性说明。
- Touch Bar 增加本地 token 消耗统计，显示 `昨日` 和 `累计` 用量。
- 重置时间统一显示为 `MM月dd日 HH:mm 重置`，让 5 小时额度和周额度两行更容易对齐阅读。
- 本地 token 统计改为后台读取，避免刷新时桌面 HUD 和菜单栏短暂卡住。
- 更新 README 宣传图，并新增一张更清晰的 Touch Bar 细节图。

### 0.1.3 - 2026-06-13

- 新增 LaunchAgent 启动器，首次运行后可在 Codex 启动时自动打开额度条。
- 新增 `scripts/package-dmg.sh`，可生成用于分享安装的 DMG。
- README 加入第一版项目宣传图。

### 0.1.2 - 2026-06-11

- 修正 Finder 详情列表小图标模式下图标显示成彩色噪点的问题。
- 调整 `scripts/make-app-icon.py`，改用 Pillow 的标准 ICNS 写入器生成兼容的小尺寸图层。

### 0.1.1 - 2026-06-11

- 修正 Finder 列表等小尺寸场景下 App 图标显示不清楚的问题。
- 新增 `scripts/make-app-icon.py`，用于重新生成带专门小尺寸图层的 `AppIcon.icns`。

### 0.1.0 - 2026-06-10

- 首次开源发布 Swift/AppKit 菜单栏、桌面 HUD 和 Touch Bar 应用。
- 通过本机 Codex app-server 读取 5 小时额度和周额度，不抓网页、不需要 API Key。
- 菜单栏、HUD 和 Touch Bar 使用同一份额度状态，并支持刷新失败时保留旧数据。

## 隐私

TouchBarCodexToken 不保存密码、API Key、授权码或账号凭据。额度与账号 Token 统计通过本机 Codex app-server 获取；app-server 使用现有登录态联网读取服务端数据，统计仅显示在本机 UI 中。应用只在内存中保留统计和用于识别账号变化的账号元数据，不写入磁盘、不打印账号信息，也不上传本机会话日志。旧版宿主若不支持 `account/usage/read`，将显示不可用提示，不回退到不同口径的本地总量。

## 许可证

MIT License
