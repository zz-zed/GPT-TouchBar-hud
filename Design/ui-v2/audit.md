# 现状审计与信息架构

证据基线：2026-09-17，Git `bb434443e3ade67e2cc92f4b5cefb6d272920d77`。
本次为代码与交互结构审计。原生应用通过名称、Bundle ID 与完整路径读取时出现超时/多副本歧义，未取得可用实时截图。Marketing 的 hero 图片标明“功能示意”，不作为实机证据。下面的可读性风险需要原生实现后通过截图与实机验证。

## Current State

| 界面 | 当前职责与行为 | 代码证据 |
| --- | --- | --- |
| Menu Bar | 图标、5h/7d 剩余或重置次数；悬停含账号 token 和任务详情 | `Sources/AppDelegate.swift`：updateStatusTitle |
| Status Menu | 版本/检查更新在前，随后浮窗、刷新、任务开关、设置、退出 | `Sources/AppDelegate.swift`：makeStatusMenu |
| Desktop HUD | 250×34 双额度胶囊，单额度 166×34；任务文案额外加宽；刷新/隐藏按钮各 20×20 | `Sources/CompactHUDViewController.swift`：configure、setMetricCount |
| HUD Context Menu | 重复版本/更新、隐藏、刷新、完整外观设置、退出 | `Sources/AppDelegate.swift`：makeHUDContextMenu |
| Touch Bar | 中文 600、英文 460 点宽，30 点高；图标与任务 badge，最多两行额度、重置/到期时间和 token，条件显示点数 | `Sources/TouchBarRateLimitsView.swift`：configure、update |
| Settings / Appearance | 语言、常驻、五种颜色、两组透明度档位，主要通过子菜单操作 | `Sources/HUDAppearance.swift`、AppDelegate.makeAppearanceSettingsMenu |

当前已经共享 `RateLimitDisplayState`，包含额度、重置券、点数、账号 token 与任务状态。无需另造数据源。额度显示的是剩余百分比，计算为 `max(0, min(100, 100 - usedPercent))`；未知值必须与 0% 区分。

## Problems / Design Opportunities

下表 After 均为设计提案，尚未实现。

| Before | After | Why |
| --- | --- | --- |
| 两类菜单顶部都先出现版本与更新 | Status Menu 先展示状态摘要，更新移到末组；HUD 右键聚焦当前浮窗 | 高频查看额度时减少无关内容 |
| 颜色、文字透明度、背景透明度分散在层级菜单 | 独立设置窗口包含“通用 / 外观 / Touch Bar”，提供即时预览 | 避免逐项打开子菜单，方便看见组合效果 |
| HUD 宽度按任务文案 intrinsicContentSize 增长，改变窗口 origin 保持中心 | 按最新确认：Quiet 根据可见内容自动伸缩，不预留空任务区域 | 避免内容减少后留下空白，保留一致间距 |
| HUD 额度点用绿/黄/红，任务用青/绿；色彩语义接近 | 额度使用数值与明确警示，任务使用图标加文字；普通额度减弱色彩 | 区分执行状态和可用额度，不只靠颜色 |
| 刷新中/失败但存在旧额度时 HUD 仍显示原数据，细节依赖 tooltip | 刷新按钮反馈、失败后保留旧数值并明确标记 | 旧值不能被误读为刚更新的数据 |
| HUD 刷新/隐藏命中区域 20×20 | 刷新提高到 26×26；按用户修订移除浮窗关闭按钮，隐藏统一由菜单操作 | 提高密集工具条操作可用性 |
| 前景透明度最低可达 10%，同时影响文字和按钮 | 保留旧偏好迁移；新默认保持可读性，并响应减少透明度/增加对比度 | 低透明度在复杂背景上存在可读性风险 |
| Touch Bar 已处理 Reduce Motion 与可见性暂停 | 保留已有生命周期和无障碍行为；静态方案通过后再决定是否保留呼吸 | 避免重新引入常驻 CPU 或系统控制条回归 |
| 菜单的很多标题硬编码中文，信息语言已有中英选项 | 设置语言的作用范围需要在新版明确；全界面文案成组管理 | 避免设置含义与实际显示不一致 |

## Information Architecture Proposal

| 层级 | 持续显示 | 展开后显示 | 设置 |
| --- | --- | --- | --- |
| Menu Bar | 简明额度与任务提示 | 统一摘要、错误/更新时间、重置时间、token | 设置统一入口 |
| HUD | 所选方案的任务/额度、刷新和隐藏 | 悬停含时间；右键含显示相关快捷操作 | 打开同一设置窗口 |
| Touch Bar | 额度、任务提示，依窗口数据决定一或两行 | 保留现有到期、点数、token 的展示能力 | 常驻开关与语言/布局 |

建议 Status Menu 顺序：状态摘要 → 刷新 → 显示/隐藏 HUD、Touch Bar 常驻 → 设置… → 关于/检查更新 → 退出。
建议 HUD 右键顺序：刷新 → 隐藏浮窗 → 外观设置… → 通用设置…；退出保留在主菜单，减少隐藏和退出混淆。
建议设置分组：通用（信息语言、实验性任务状态），外观（布局、背景颜色、背景与文字透明度、预览），Touch Bar（常驻及不可用解释）。这些是待后续原型验证的结构，并非已确认的最终 UI。

## 必须覆盖的边界

- 5h+7d、只有5h、只有7d、重置券+7d、只有重置券、没有数据。
- 0%、100%、缺失值、额度过低、刷新中、刷新失败保留旧数据。
- 点数为零/缺失/无限时按既有规则隐藏；重置券不可伪装成百分比。
- token 昨日/累计、旧值标识、账号切换失效规则保留。
- 任务执行、最近完成、空闲、关闭实验功能，中英长文案。
- HUD 隐藏后能从菜单恢复；默认启动隐藏 HUD；隐藏不停止常驻 Touch Bar。
- Touch Bar 系统控制条、关闭替代项、跨 App 不抢焦点、休眠唤醒。

原型第一轮重点验证 HUD 信息层级，不模拟全部 Touch Bar 功能，也不以网页表现替代 AppKit 验收。
