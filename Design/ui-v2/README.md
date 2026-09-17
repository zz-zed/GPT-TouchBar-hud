# GPT TouchBar HUD · 全面设计升级

2026-09-17：已按用户确认的 Quiet HUD、Status-first 菜单、Balanced Touch Bar 完成原生 Swift/AppKit 实现，并生成本地 Release 应用。见 [原生实现与验收边界](implementation.md)。下方原型保留为设计过程记录。

- [现状审计与信息架构](audit.md)
- [设计原则与实现边界](design-principles.md)
- [Touch Bar 三方案原型](prototypes/touchbar.html)：Compact / Balanced / Task-first。
- [菜单与设置三方案原型](prototypes/menu.html)：Compact / Grouped / Status-first，共用可操作设置窗口。
- [HUD 三方案原型](prototypes/hud.html)：直接用浏览器打开，或运行 `python3 -m http.server 8765 --bind 127.0.0.1 --directory Design/ui-v2/prototypes` 后访问 http://127.0.0.1:8765/hud.html。
- [基线记录](baseline/git.txt)；构建与回归日志位于 `baseline/`。
- [验证记录](validation.md)

## 方案选择

| 方案 | 探索轴 | 适合的使用方式 | 代价 |
| --- | --- | --- | --- |
| Quiet | 单行、最小高度 | 工作时顺便看任务和额度 | 字号较小，重置时间需悬停 |
| Status-first | 双层、任务优先 | 频繁判断任务执行/完成状态 | 高度增加；状态关闭时保留头部 |
| Data-first | 双额度条、时间常显 | 根据额度和重置时间安排工作 | 空间占用最多 |

键盘 1 / 2 / 3、左右方向键切换，URL 保存当前方案。所有数值为模拟数据。支持七种额度情景、四种任务情景、深浅背景、对比度、刷新、隐藏恢复和拖动。无真实账号调用。

## 当前进度

1. 已完成：Quiet、Status-first、Balanced 设计收敛及原生实现。
2. 已完成：627 项计数检查、首次打开专项、Release 构建与严格签名校验。
3. 用户已在可读性与日期对齐修订后确认实机可用；VoiceOver 等未单独确认的专项仍保留验证边界。
4. 本地构建位于 `build/GPT TouchBar HUD.app`。未替换已安装应用，未合并、推送或发布。

实现位于现有 `feat/desgin` 分支，基线为 `bb434443e3ade67e2cc92f4b5cefb6d272920d77`。

## 已确认决策

2026-09-17：用户明确“采用Quiet”。HUD 布局方向已确定；后续不再重复请求 HUD 方向选择。先完成菜单与 Touch Bar 设计收敛，再统一进行原生实现。原有探索文件暂留作设计溯源，未删除。

2026-09-17 修订确认：菜单采用 Status-first。菜单栏常驻任务图标必须保留，执行中蓝色、完成绿色、未知灰色、空闲/关闭任务显示时系统中性色；额度文字不随图标变色。Quiet 浮窗移除关闭按钮，宽度按可见任务、额度和刷新按钮的内容自动伸缩；隐藏功能保留于菜单。此决定取代此前“固定外框/预留任务区”的提案。

菜单栏外显还必须覆盖重置卡：缺少 5h 且有可用重置卡时，显示“重置 3次 + 7d”；只有重置卡时只显示重置次数。菜单详情展示到期时间，不将重置次数转换成百分比。

图标修订：菜单栏闪电使用横向形态，避免与 macOS 电池充电标识相似；保留圆形底与任务状态颜色。原生实现继续使用 `bolt.horizontal.circle.fill`。

用户已确认横向闪电及全部菜单/HUD修订，进入 Touch Bar 布局探索。已有 HUD 与菜单选择不再重新确认。

用户已选定 Touch Bar Balanced，要求收紧信息列间距、提高点数展示效率。修订采用内容宽度列、6px 间距；点数显示在紧接用量的独立两行小区块，仅存在时加入，不再预留固定点数列或移除额度进度条。

用户最终确认 Balanced 修订，原生实现已采用该版本，无需重新选择方案。
