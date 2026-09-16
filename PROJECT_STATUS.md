# PROJECT_STATUS

最后更新：2026-09-16

## 项目概况

TouchBarCodexToken 是一个 Swift/AppKit macOS 菜单栏、桌面 HUD 和 Touch Bar 小工具。应用通过本机 ChatGPT/Codex 包内的 `codex app-server` 调用 `account/rateLimits/read` 和 `account/usage/read`，显示额度窗口、可用重置次数、额度点数和 GPT 账号 Token 用量。

- 当前分支：`main`
- 当前源码版本：`0.1.20`，Build `21`
- GitHub `main` 目标版本：`0.1.20`（2026-09-16）
- 正式标签 / GitHub Release：尚未创建

## 0.1.20 修正系统关闭按钮

- 用户明确反馈 0.1.19 普通状态下关闭按钮仍存在，不能将其认定为修复成功。
- 在独立自有诊断进程中用 LLDB 只读检查已加载系统框架，`DFRSystemModalShowsCloseBoxWhenFrontMost` 函数体只有 `ret`。未附加或修改 ChatGPT、ControlStrip 或系统进程。
- 同时检查 AppKit `NSSystemModalTouchBarOverlay._updateCloseButton`：后台呈现时，无显式 escape 替代项就使用系统关闭按钮；高优先级自定义项可在前后台被采用。
- 改为公开 `escapeKeyReplacementItemIdentifier` + template item，为本应用 bar 提供高优先级零宽度空视图。保留 placement 0，系统展开后的覆盖层不受此项配置影响；删除无效 DFR 函数调用。
- 136 项排版/替代项检查与 23 项控制器检查通过；Release 构建、严格签名校验通过。已启动 0.1.20 / Build 21，用户实机确认：“× 已消失，展开收起正常”。

## GitHub Release 自动打包

- `.github/workflows/build-dmg.yml` 保留 `main`、Pull Request 和手动触发的双架构构建校验，并新增 `release.published` 触发器。
- Release 触发时检出 Release Tag；要求 Tag `vX.Y.Z` 与 `Resources/Info.plist` 的 `X.Y.Z` 一致，避免版本和安装包错配。
- Apple Silicon 与 Intel runner 分别生成带 `arm64` / `x86_64` 后缀的 DMG，并验证 App 签名、DMG 和二进制架构。
- 两个 DMG 构建成功后，自动生成 `SHA256SUMS.txt`，使用 GitHub 提供的临时 Token 上传为该 Release 的 Assets。
- 当前没有创建 Tag 或 GitHub Release；首次发布时才会执行 Release Assets 上传链路。

## 本地开发：0.1.19 去除常驻关闭按钮（已取代）

- 去掉 Token 内容视图自带的退出按钮，保留菜单栏及 HUD 退出方式；释放的 30 点转给文字区域。
- 通过 DFRFoundation 的动态符号控制本应用 modal 的 close box：呈现前 false、撤销后 true，符号缺失时不调用。不修改系统全局设置或控制条原生展开/收起项目。
- 本机符号检查可用；129 项 AppKit 布局检查、23 项控制器检查、Release 构建与签名校验通过。
- 已重启到 0.1.19 / Build 20，但实体 Touch Bar 实测普通状态仍有系统关闭按钮，因此该方案未生效并已由 0.1.20 取代。

## 本地开发：0.1.18 布局与系统控制条共存

- 从全宽 `placement: 1` 改为应用区域 `placement: 0`，不改系统设置、不模拟亮度/音量按钮；继续使用系统原有控制条。
- 两种 Touch Bar 模式都在额度项后添加弹性空间，取消视觉居中留白；内容宽度 750 → 600 点，关闭按钮和图标间距缩小，保留系统自身左侧按钮区域。
- 昨日/累计栏从 66 点扩为至少 120 点，设置必需的抗压缩优先级；进度条可缩至 40 点，有行内点数时省去进度装饰以保留数值。
- 宿主启动只开启菜单栏和 Touch Bar，浮窗默认隐藏，菜单手动显示仍保留。
- 128 项 AppKit 排版检查通过，覆盖双额度、重置券、周额度、USD 余额、旧数据标记，逐项检查文字实际宽度与边界；23 项控制器检查通过。
- Release 构建、签名校验通过，已启动本地 0.1.18 / Build 19。用户实机确认：系统控制条展开时 Token 隐藏，收起后恢复。
- 启动后只读窗口检查 `running=true onscreenWindows=0`，确认没有显示浮窗。主进程第 106 秒累计 CPU 时间 1.98 秒；短时单次采样 1.1%，子进程 0.0%。
- 尚未提交或推送；跨更多设备、系统版本、休眠场景仍需后续实机验证。

## 本地开发：0.1.17 账号 Token 统计

- 根因：此前扫描 `~/.codex/sessions` 得到本地会话用量；GPT 个人页面读取账号服务端统计，两者口径不同。0.1.15 只验证新旧本地算法一致，不代表与 GPT 页面一致。
- 改为官方 app-server `account/usage/read`；累计直接用 `summary.lifetimeTokens`，昨日按本地公历日期匹配服务端 `dailyUsageBuckets.startDate`，不合计有限日期桶来冒充累计。
- 已在本机成功调用接口，格式化后的昨日、累计结果与用户截图一致。服务端日期标签的全局时区规则仍未见文档承诺；当前上海时区日期匹配已实测。
- 不请求登录凭据、不新增直接 HTTP 调用；仅内存缓存。监听账号变更通知，并在查询前后核对 `account/read` 元数据，清除或丢弃跨账号旧结果；元数据未提供独立 workspace ID，同邮箱同套餐 workspace 切换依赖宿主账号变更通知。
- 5 分钟统计刷新，10 秒手动防抖，30 秒单次 RPC 超时，失败退避 5/10/20/30 分钟；额度查询与统计独立。空值显示 `--`，旧数据标记 `*`，菜单栏悬停查看详情。
- 账号统计回归覆盖空值、零值、重复桶、跨日/DST、缓存、失败退避、账号切换及在途回调作废；未对真实账号执行切换或退出登录。
- 旧扫描器保留供对照，应用运行路径已停止调用。
- 76 项回归通过（账号统计 37、旧扫描器 18、Touch Bar 21）；包含账号查询前后校验的真实只读调用成功，昨日和累计显示与截图一致。
- Release 构建及 `codesign --verify --deep --strict` 通过，已重启本地 0.1.17 / Build 18。进程启动后第 33—73 秒五次 CPU 采样：主进程 0.0%、0.0%、0.0%、0.1%、0.0%；app-server 子进程 0.6%、0.0%、0.0%、0.0%、0.1%。主进程第 73 秒累计 CPU 时间 1.30 秒；这是短时观测，非长时间稳定性保证。
- 未提交、未推送或发布；实体 Touch Bar 的文字裁切需用户目视确认。

## 本地开发：0.1.16 ChatGPT 图标

- Touch Bar 左侧改为读取本机 ChatGPT 的 `icon-chatgpt.png` / `.icns`，移除旧 Codex 图标路径，悬停提示改为 ChatGPT。
- 两种 Touch Bar 模式共用该视图；图标尺寸和布局不变。
- 已检查本机源图，Release 构建及签名检查通过；已重启本地应用加载新图标。

## 本地开发：0.1.14 Touch Bar 常驻

- 原因：0.1.13 仍使用 HUD 的 responder chain 提供 Touch Bar，切换到其他 App 后被替换。
- 独立控制器使用运行时检查的私有 system-modal API 呈现完整额度条，切换 App 后合并延迟重新呈现，不主动激活额度条 App。
- 菜单栏和 HUD 右键菜单 → 设置 → Touch Bar 常驻；默认开启，保存选择，关闭后立即撤销系统级显示。
- 隐藏 HUD 不影响常驻；休眠/会话切换期间暂停，恢复时重新呈现；关闭或退出会取消待执行恢复并移除监听。
- 显示/撤销接口缺失或签名不兼容时禁用常驻开关，回退为原有焦点绑定显示。
- 回归检查：`bash scripts/test-touchbar.sh`；本机接口冒烟检查：`bash scripts/test-touchbar.sh --smoke-system`。
- 本轮已验证：21 项控制器回归检查通过；当前 macOS 27.0 的私有方法签名可用，真实显示/撤销调用正常返回，前台 App 未改变。调用正常返回不等同于实体 Touch Bar 显示成功。
- 本机构建：`scripts/build-app.sh` 成功生成 `build/TouchBarCodexToken.app`（0.1.14 / Build 15）；本轮 SwiftPM Release 构建成功，未使用后备路径。
- 实体 Touch Bar 验收待完成：跨 App 输入、切换常驻开关、隐藏 HUD、休眠恢复、退出后恢复系统控制条，以及旧款 Touch Bar 上的系统按键和内容宽度。
- 以下 0.1.6—0.1.13 验证说明为历史记录，不能作为 0.1.14 的实机验证结果。

## 本地开发：0.1.15 CPU 优化

- 用户已反馈 0.1.14 常驻可以正常显示，但 CPU 飙升；本机进程读数曾达到 76.5% / 96.9%。
- 5 秒调用栈采样定位到 `LocalTokenUsageReader`：全量字符串扫描、Unicode 搜索和逐记录创建日期解析器。历史日志目录约 790 MB，额度刷新后反复执行全量统计。
- 改为串行、内存缓存的增量日志扫描：文件元数据与 EOF 指纹检测、分块字节扫描、复用日期解析器、日维度聚合；增加 60 秒统计节流。
- 18 项统计与增量 I/O 检查通过，覆盖无变化时零正文读取、追加只读增量、跨块 Unicode、半条记录、无换行完整记录、跨日、时区变化、截断、覆盖、替换、删除和坏行。
- 固定日志快照对照：旧版 32.101 秒（CPU user 30.88 秒）；新版首次 2.205 秒，再次 0.015 秒（两次合计 CPU user 1.33 秒）。昨日和累计 token 的新旧统计结果完全一致。
- 已构建 0.1.15 / Build 16，本机签名检查通过。上述时间为本机一次对照，后续新进程首次仍需建立内存索引。
- 已重启本地应用到 0.1.15。启动后约第 45—95 秒的六次 CPU 采样为 0.0%、0.4%、0.6%、0.8%、2.1%、0.7%，覆盖一次定时刷新；进程 95 秒累计 CPU 时间为 3.29 秒。39 项回归检查通过（token 统计 18 项 + Touch Bar 21 项）。

## 已完成

- 兼容 `/Applications/ChatGPT.app` 和旧版 `/Applications/Codex.app` 中的 app-server。
- LaunchAgent 可识别 `ChatGPT`、`Codex` 和 `GPT`，宿主启动时自动拉起额度条。
- 宿主退出时自动关闭额度条；手动退出锁仍然保留。
- 菜单栏、HUD 和 Touch Bar 共用同一份 `RateLimitDisplayState`。
- 刷新失败时保留旧额度数据；账号 Token 独立后台查询并标记过期，账号无法确认时清除旧统计。
- 重置时间使用双位 `MM月dd日 HH:mm` 格式。
- HUD 双额度宽度已从 `238px` 调整为 `250px`，单个额度项从 `70px` 调整为 `76px`，避免 `5h 100%` 的百分号被裁切。

## 0.1.6 更新

以下改动已经完成构建、本机运行测试并推送到 `main`：

- 严格按照 `windowDurationMins` 区分 5 小时和周额度，不再把唯一的周额度重复映射为 `5h`。
- 解析 `rateLimitResetCredits`，共享状态中增加可用完整重置次数和最早到期日期。
- 有 5 小时窗口时显示 `5h + 7d`。
- 只有周额度且存在重置次数时显示 `重置 x次 + 7d`。
- 没有 5 小时窗口和重置次数时只显示周额度，HUD 自动收窄到 `160px`。
- Touch Bar 第一行可动态切换为“5 小时”或“重置券”。
- Touch Bar Codex 图标改为优先读取 ChatGPT 包内的白底 `icon-codex-light.png`，黑底图标、旧 Codex 图标和 App 图标作为后备。
- Touch Bar 将重置/到期文字、`|` 分隔线、昨日/累计用量拆成固定列，保证上下两行分隔线对齐。
- README 已增加 `0.1.6` 功能说明，并为 `0.1.0` 至 `0.1.6` 的更新记录补齐日期。

涉及文件：

- `README.md`
- `Resources/Info.plist`
- `Sources/AppDelegate.swift`
- `Sources/CompactHUDPanel.swift`
- `Sources/CompactHUDViewController.swift`
- `Sources/LimitModels.swift`
- `Sources/RateLimitStore.swift`
- `Sources/TouchBarRateLimitsView.swift`

## 0.1.7 更新

- HUD 透明度最低支持从 `45%` 放宽到 `10%`。
- 设置菜单新增 `10% / 20% / 30% / 40% / 50%`，并保留原有较高透明度档位。
- 该版本的透明度只影响 HUD 背景，文字、状态点和操作按钮保持完全不透明。
- 已完成 Release 构建和本机重启验证，并推送到 `main`。

## 0.1.8 更新

- HUD 胶囊背景、额度文字、状态点、刷新和退出按钮改为使用统一透明度。
- 修复低透明度下背景与前景视觉不统一的问题。
- 已完成 Release 构建和本机重启验证，并推送到 `main`。

## 0.1.9 更新

- 桌面 HUD 新增原生右键菜单，可直接隐藏浮窗、刷新额度、修改颜色和透明度或退出。
- 右键菜单与菜单栏共用外观设置状态，当前颜色和透明度勾选保持同步。
- 右键隐藏 HUD 后可从菜单栏重新显示。
- 已完成 Release 构建和本机重启验证，并推送到 `main`。

## 0.1.10 更新

- HUD 背景透明度与文字透明度拆分为两个独立设置。
- `背景透明度` 只控制胶囊底色；`文字透明度` 同时控制额度文字、状态点、刷新和退出图标。
- 菜单栏和 HUD 右键菜单共用两组外观状态，当前选项保持同步。
- 旧版统一透明度设置会自动迁移到新的背景和文字透明度，不会丢失用户选择。
- 已完成 Release 构建和本机重启验证，并推送到 `main`。

## 0.1.11 更新

- 解析新版 app-server `RateLimitSnapshot.credits` 中的美元点数余额，并格式化为两位小数。
- 只有周额度时，Touch Bar 使用独立第二行显示 `还剩点数：US$XX.XX`。
- 同时存在 5 小时和周额度时，点数跟随第二行周额度显示，保持最多两行。
- 点数为 0、不可用、无限额度或接口未返回余额时自动隐藏。
- 降低额度行固定高度约束优先级，使隐藏行真正折叠并修复单行内容垂直偏移。
- 已用本机 app-server 实际响应验证点数字段，并完成 Release 构建和本机重启验证后推送到 `main`。

## 0.1.12 更新

- HUD 单个额度区域从 `70px` 加宽到 `76px`，修复 `5h 100%` 和 `7d 100%` 百分号被裁切的问题。
- 双额度 HUD 宽度从 `238px` 调整为 `250px`，单额度 HUD 从 `160px` 调整为 `166px`。
- 胶囊高度、操作按钮尺寸和内部间距保持不变。
- 已完成 Release 构建和本机重启验证，并推送到 `main`。

## 0.1.13 更新

- 修复新版 GPT 接管 Touch Bar 后，点击桌面 HUD 无法重新显示额度条的问题。
- 用户点击 HUD 时显式激活额度条并让面板成为 key window。
- Touch Bar 在创建后重置 first responder，强制 macOS 重新读取额度条。
- 自动启动路径不主动激活应用，继续避免抢占 GPT 输入焦点。
- 已完成 Release 构建和本机重启验证，并推送到 `main`。

## 验证状态

- `bash scripts/test-account-token-usage.sh`：37 项通过。
- `bash scripts/test-token-usage.sh`：18 项通过。
- `bash scripts/test-touchbar-layout.sh`：136 项通过。
- `bash scripts/test-touchbar.sh`：23 项通过；本机 system-modal 方法签名可用。
- `git diff --check`：通过。
- `scripts/package-dmg.sh`：通过，生成并校验 `dist/TouchBarCodexToken-0.1.20.dmg`；App 严格签名检查通过，当前本机构建架构为 arm64。
- SwiftPM Release 构建成功；链接器仅报告本机 Command Line Tools 的两个缺失搜索路径警告，不影响产物生成和校验。
- GitHub Actions YAML 已通过本地语法解析；Release 事件上传分支尚未通过真实 Release 触发，因为远端当前没有 Tag 或 Release。

## 未解决和注意事项

- `0.1.20` 尚未创建 Git 标签或 GitHub Release；发布 `v0.1.20` Release 后将由 Actions 自动生成并上传 DMG。
- 项目已增加 Touch Bar 控制器回归检查；额度接口结构变化仍主要依赖本机 app-server 和实体 Touch Bar 验证。
- App 尚未使用 Apple Developer 证书签名和公证，公开分发时仍可能出现 macOS 安全提示。
- 以下 Marketing 文件是未跟踪草稿，除非明确要求，否则不要加入提交：
  - `Marketing/promo-style-a-touchbar-soul.png`
  - `Marketing/promo-style-b-warm-fresh.png`
  - `Marketing/promo-style-c-editorial-clean.png`
  - `Marketing/promo-style-d-tech-board-v2.png`

## 建议下一步

1. 在实体 Touch Bar 上继续观察 ChatGPT 图标、重置券行和两行 `|` 分隔线在不同额度值下的对齐情况。
2. 按需要创建 `v0.1.20` GitHub Release；无需在本地手动打包 DMG。
3. 后续 app-server 返回结构变化时，优先检查额度窗口时长和重置券字段。

## 常用命令

```bash
scripts/build-app.sh
scripts/package-dmg.sh
open build/TouchBarCodexToken.app
git status --short --branch
```
