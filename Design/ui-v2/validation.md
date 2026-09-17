# 验证记录

日期：2026-09-17。当前结果见“原生实现验证”；其后保留设计探索阶段的历史记录。历史段落中的“Swift 未修改”等描述仅适用于当时阶段。

## 原生实现验证

本地 Release 构建成功，`scripts/build-app.sh` 内的严格签名校验通过。产物为 `build/GPT TouchBar HUD.app`，仍使用原版本标识，属于本地开发构建。链接器提示 Command Line Tools 的两个搜索目录缺失，但未阻止构建。

| 脚本 | 计数检查 |
| --- | ---: |
| test-account-token-usage.sh | 53 |
| test-app-migration.sh | 4 |
| test-app-update.sh | 38 |
| test-task-status.sh | 34 |
| test-token-usage.sh | 18 |
| test-touchbar-layout.sh | 291 |
| test-touchbar.sh | 34 |
| test-design-layout.sh | 155 |
| 合计 | 727 |

另通过更新器 shell 语法/无效目标拒绝，以及 `test-first-open.sh` 的取消、隔离属性定向移除、保留无关属性、重复运行、符号链接拒绝、哈希不符、参数拒绝与签名篡改检查。首次打开测试只操作临时副本并抑制真正启动。

新增集成检查覆盖：HUD 仅保留刷新按钮；任务和额度减少时收窄；重置次数可见；刷新中禁用；设置预览不改变设置窗口大小；常驻接口不可用时开关禁用；中英双语、单/双额度与点数有无时的文字边界和 30 点高度。原排版测试按可见标签遍历计数，新布局由 321 项变为 291 项，并非删除了 30 个固定用例。

首次并行执行 GUI 检查出现前台焦点断言失败；停止并行 GUI 检查后，生命周期脚本独立运行全部通过。原生视图使用测试数据导出至 `native/`：Quiet、Balanced 和菜单摘要已查看；设置内容可见，但 AppKit 缓存截图的标签栏呈黑块，不作为完整视觉验收。原生 CUA 窗口读取仍超时。

未验证：实体 Touch Bar 裁切与系统控制条行为、完整 VoiceOver、真实账号切换、系统无障碍设置实际切换、深浅色原生菜单/设置全流程。本次没有替换 `/Applications` 应用、合并、推送或发版。日志见 `native/*-verification.log`。

## 原始代码基线

`swift build` 成功（34.23 秒）。链接器提示两个 Command Line Tools 搜索目录缺失，未阻止构建。完整记录见 `baseline/build.log`。

项目 Package.swift 没有 SwiftPM test target；因此运行仓库自带脚本，而不是把 `swift test` 无测试当作通过。

| 脚本 | 结果 |
| --- | --- |
| test-account-token-usage.sh | 53 项通过 |
| test-app-migration.sh | 4 项通过 |
| test-app-update.sh | 38 项通过；shell 语法与无效目标拒绝通过 |
| test-task-status.sh | 34 项通过 |
| test-token-usage.sh | 18 项通过 |
| test-touchbar-layout.sh | 321 项通过 |
| test-touchbar.sh | 34 项通过；本机 system-modal 签名可用 |

共 602 项计数检查。test-first-open.sh 是打包首次打开专项，依赖已构建 app 副本并修改隔离属性；本次仅设计探索，未执行。签名可用不代表实体硬件行为已验证。

## 原型

通过 Codex 内置浏览器打开本地 HTTP 页面，逐一截图检查 Quiet、Status-first、Data-first，并验证：

- 三方案 × 七额度情景，共 21 组合；100%、单周、重置券、缺失值及错误提示均存在。1280×860 桌面视口下 `.hud.scrollWidth <= .hud.clientWidth` 全部通过。
- 三方案 × 四任务情景，共 12 组合，任务执行/完成/空闲/关闭均正确显示。
- 三方案的刷新、隐藏、恢复可用；刷新模拟完成后保留同一数据。
- 深色背景与提高对比度开关可切换。
- 数字键 3 切至 Data-first，重新加载后通过 URL 保持方案。
- Data-first 拖动产生 `translate(80px, -80px)`，恢复按钮可复位。
- 渲染检查时浏览器 error 日志为空。
- 默认窄面板和 1280×860 桌面尺寸均查看过，已重置临时视口。视口重置后的额外 DOM 几何检查工具超时，未计为通过；通过最新可访问性树确认页面返回 Quiet 且主要操作存在。

首次快速检查有部分内容在 requestAnimationFrame 挂载前读取为空；随后增加等待 `.hud` 可见，21 组合内容与布局检查全部通过。浏览器截图见任务工具记录，未另存为本地 PNG。

## 当前限制

原生应用界面读取超时，尚无实时 HUD/Menu 截图。现状判断基于源码。HTML 中的桌面与菜单栏是固定环境示意，只有 HUD 和右侧调试控件可交互，不是完整应用原型。

尚未验证 AppKit material、VoiceOver 完整朗读、系统无障碍偏好切换、真实账号切换或实体 Touch Bar 裁切/系统控制条。生产 Swift 未修改，无安装、合并、推送或发布。

## 菜单探索（Quiet 选定后）

新增 `prototypes/menu.html`，三方案共用 Quiet HUD 与设置窗口。通过浏览器逐一查看 Compact、Grouped、Status-first 截图；三方案 × 四额度情景的内容检查通过。实际验证了隐藏/恢复浮窗、常驻不可用解释、设置分组、中文切英文、颜色切换与背景不透明度 75% 的即时反馈。

初次生成时 JavaScript 字符串换行转义错误，已修复并重新加载；后续未出现新 error，日志中仍保留首次加载的历史 SyntaxError。设置弹窗内 Playwright 标签定位失败后，改用实时可访问性树完成交互验证。快捷键已接入模拟操作，但未逐项实测；更新/退出仅显示说明，不操作真实应用。生产代码未改，因此未重复原生基线回归。

## Status-first 修订：图标、自动宽度、重置卡

菜单栏恢复常驻状态图标，图形为网页近似；原生实现保留现有 `bolt.horizontal.circle.fill`。浏览器验证四种任务状态图标始终为 1 个，颜色分别为执行蓝、完成绿、空闲中性、未知灰；控制台无 error。

移除两份原型的浮窗关闭按钮。菜单原型实测：双额度 231.3px、仅周额度 175.1px、重置卡+周额度 234.0px、仅重置卡 177.5px；均含执行中任务与刷新按钮。菜单栏、菜单详情和 Quiet HUD 的重置次数同步，详情包含到期日期。截图已查看，生产 Swift 尚未修改。

## Touch Bar 三方向探索

新增自包含 `prototypes/touchbar.html`，ChatGPT 图标读取本机 `/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png` 并嵌入页面。内容区域为 600×30，窄屏横向滚动，不缩小布局；英文方案本轮同样以 600 点对比，不宣称已验证现有原生 460 点宽度。

三方向（Compact / Balanced / Task-first）× 中英双语 × 10 数据情景，共 60 组 DOM 子项溢出检查通过。覆盖常规、100%、低额度、仅周、重置卡+周、仅卡、双额度+点数、周+点数、旧值、无数据。控制台 error 为空。逐一查看三方案桌面截图，Task-first 四种任务反馈与系统展开模拟按钮已验证。临时桌面视口已复位。

所有数据为 fixture，系统控制按钮只给模拟反馈，不控制真实系统。网页对比不能证明 AppKit 字形、缩放或硬件控制条行为。生产 Swift 未改，本轮不重复基线构建。

## Balanced 间距与点数修订

首次 20 组合检查中，中文常规内容区由 600px 收至约 296.5px，双额度+点数约 364.8px，保持 30px 高和两根进度条。发现英文 AVAILABLE 溢出，已改为 Ready；单行额度的用量改为两行，进一步减少横向占用。最后两项修复后的 DOM 批量检查遭遇浏览器工具超时，未声称该轮全部通过。通过实时可访问性树和截图复核中文单周+点数、双额度+点数，两组信息完整、无明显裁切。

本轮是原型修订；未修改 Swift、未安装应用。

## Touch Bar 可读性修订

根据实机反馈，正文由 10 点 Medium 改为 Bold，重置卡/周限额标题及日期由灰色改为白色；“可用”提示由 8 点提升为 10 点 Bold 白色。保留低额度红色警示与进度条颜色。Touch Bar 中文到期日期移除“到期”后缀，与额度日期使用相同格式和共享列起点；菜单及悬停提示保留完整到期含义。

291 项布局检查及 155 项集成检查通过，Release 重新构建成功并通过签名验证。新增原生测试截图 `native/balanced-reset-alignment.png`。本轮未替换已安装应用。

## 用户实机验收

用户在可读性与日期对齐修订后反馈“实测已经可以了”，确认当前版本可用。此反馈补充此前自动化检查无法覆盖的实机显示验证；未单独确认的 VoiceOver 等专项不据此认定为通过。
