# 0.1.29 发布准备：Build 32

2026-09-21。当前候选为 **0.1.29 / Build 32**，在 Build 31 基础上收紧刘海展开面板并柔化四角。本地 main 的功能构建输入为 `fa9261b3d3b8e42b1491d98ab4c5f431037839e6`；后续提交仅保存验证记录。没有推送、创建标签、公开发布或替换已安装 App。

## 本次界面调整

以 32 pt 刘海安全区为例，展开尺寸由 800 × 280 pt 改为 520 × 250 pt，矩形占用面积减少约 42%。顶部由直角改为 26 pt 连续曲线，底部由 14 pt 增至 28 pt；圆角随实际呈现高度形成，快速反向动画也沿用当前轮廓。绘制、裁剪与点击判断共用同一路径，四个透明角均可点击穿透。外侧材质光晕收窄、减轻，并跟随圆角。

正文保留两列额度与三个详情页，调整边距以避开圆角。窄屏额外预留双行页脚高度，长内容可滚动；静止/悬停状态、启动自动识别和用户手动选择的保存规则保持原样。

![当前原生展开预览](NotchIsland/evidence/refined-synthetic-expanded.png)

该图使用正式渲染代码、演示数据和模拟摄像头，不是实体刘海屏照片。32 pt 是这一预览的安全区高度，真实尺寸按系统几何适配。

## 本次验证

| 检查 | 结果 |
| --- | --- |
| 原生刘海呈现 | `scripts/test-notch-presentation.sh` 通过 359 项，记录 283 个实际动画几何样本；包含全部四角的真实鼠标点击穿透 |
| 版式集成 | `scripts/test-design-layout.sh` 通过 158 项 |
| 视觉检查 | 已检查正常中文额度页，以及窄屏英文长内容的额度、活动、用量三页；底部按钮完整，长内容保留滚动 |
| 分发构建 | arm64 App 与 helper 优化编译、严格签名及 minos 11.0 校验通过 |
| 包版本 | 源码、build App、挂载 App plist 一致，均为 0.1.29 / Build 32 |
| DMG | 完整性、SHA-256、只读挂载通过；包内 8 个 App 文件与构建目录哈希及大小一致 |
| 首次打开助手 | 本包 CDHash 绑定、脚本语法及隔离副本回归通过；未启动真实安装 App |

原始日志位于 `build/release-evidence/build32/`；[测试摘要](validation/release-0.1.29-build32-tests.txt) 与 [候选清单](validation/release-0.1.29-artifact-manifest.json) 可随源码审阅。迁移、账号用量、任务状态、更新、Touch Bar 和 HookCore 的上一轮完整回归见 [Build 31 记录](RELEASE-PREPARATION-0.1.29-build31.md)；本次没有重跑未受影响的检查，不将它们计为 Build 32 的新执行结果。

## 当前产物

以下路径相对于 `/Users/didi/Desktop/codex-space/TouchBarCodexToken`：

- App：`build/GPT TouchBar HUD.app`
- arm64 安装包：`dist/GPT-TouchBar-HUD-0.1.29-arm64.dmg`
- 本地校验清单：`dist/SHA256SUMS.txt`
- DMG 字节数：`3101135`
- SHA-256：`aae56322d999898b2de25b0372a399dc927102376f4513af6ee4ee43119c141a`

Build 31 的 App、DMG 和校验文件已逐文件校验后保留至 `backups/notch-polish-build31/`，其 [旧清单](validation/release-0.1.29-build31-artifact-manifest.json) 继续保留。更早的 Build 30 和 worktree 归档仍在原保留目录，见 [清理记录](validation/worktree-cleanup-2026-09-21.json)。当前只保留主目录 main，没有新增 worktree。

## 发布边界

本地仅生成 arm64；Intel CI、实际 macOS 11、实体刘海黑位/接缝、全屏、菜单自动隐藏、热插拔和唤醒仍待验证。真实安装路径的自动更新链路未新增端到端验收。候选使用 ad-hoc 签名，未公证。本轮继续停留在本地准备，尚未推送 main 或 `v0.1.29` 标签，也未触发公开 Release。
