# 从源码构建与测试

[返回 README](../README.md) · [贡献指南](../CONTRIBUTING.md) · [原生刘海面板](NotchIsland/README.md) · [Hooks 实验](HOOKS-EXPERIMENT.md)

普通用户请使用 [Release 安装包](https://github.com/zz-zed/GPT-TouchBar-hud/releases/latest)，不需要自行构建。本文中的命令面向开发者，应在 macOS 的仓库根目录执行。

## 构建应用

需要 Xcode Command Line Tools 和支持 Swift 5.8 的工具链。

```bash
git clone https://github.com/zz-zed/GPT-TouchBar-hud.git
cd GPT-TouchBar-hud
scripts/build-app.sh
open "build/GPT TouchBar HUD.app"
```

`build-app.sh` 使用显式 SDK 和 `Resources/Info.plist` 中的最低系统目标，通过 `swiftc` 优化编译并链接主程序与原生 helper，然后分别签名和验证。

默认构建本机架构。只有工具链具备两种架构及对应兼容库时，才使用：

```bash
HUD_BUILD_ARCHS='arm64 x86_64' bash scripts/build-app.sh
```

两种架构的 CI 分别构建；不要把一次本机架构构建描述成通用包。

## 生成 DMG

```bash
scripts/package-dmg.sh
```

本机打包输出：

```text
dist/GPT-TouchBar-HUD-<版本号>.dmg
```

公开 Release 的分架构文件名另带 `arm64` 或 `x86_64` 后缀，见对应发布附件。

## 回归检查

先构建应用，再运行以下检查；其中 Hook 安装检查依赖打包生成的 `build/GPT TouchBar HUD.app/Contents/Helpers/HookEmitter`。

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

Hooks 测试使用隔离配置与测试 helper，不会启用用户的 Hooks。真实宿主的信任、执行覆盖和长期准确性仍需单独验证。

`experiments/task-status-hooks/` 保留早期可行性工具，不会打入 DMG。正式原生实现位于 `HookCore/` 和 `HookHelper/`，随 App 打包但默认关闭；默认任务状态继续使用本机任务索引和近期日志进行有界推断。

## 刘海模拟与原生预览

`test-notch-presentation.sh` 使用合成屏幕与摄像头几何，验证状态、动画、布局和点击路由。交互预览入口：

```bash
bash scripts/test-notch-presentation.sh --preview --debug-regions
```

预览默认展示 Peek，可显式指定 Compact：

```bash
bash scripts/test-notch-presentation.sh --preview --compact --debug-regions
```

`scripts/debug-notch-hud.sh` 保留为旧渲染器调试入口，当前原生实现以[原生刘海面板文档](NotchIsland/README.md)为准。

原生预览和自动化点击检查可能创建真实测试窗口。测试结束后检查并关闭由本次测试启动的预览与辅助窗口，不要终止用户正常运行的应用。异常退出时也应核对残留测试进程，不应只按包含“HUD”的宽泛进程名批量结束。

模拟测试不等同于实体刘海验收。实体接缝、透明角落点击穿透、全屏、自动隐藏菜单栏、多屏切换和锁屏 / 唤醒需按设备和系统单独验收。

## Touch Bar 冒烟检查

真实 system-modal 检查需要图形会话与兼容系统，会短暂呈现 Touch Bar：

```bash
bash scripts/test-touchbar.sh --smoke-system
```

请区分布局测试、真实系统接口检查与不同硬件的实际可用性。

## 发布与文档维护

[v0.1.31 发布记录](RELEASE-0.1.31.md)保存源码、CI、安装包与验证边界。双架构构建及签名检查通过，不等于 Apple 公证，也不等于实际 macOS 11 和完整自动更新链路已验收。

README 应描述已发布、可供普通用户使用的能力；仅源码可用的功能需要明确标注，不应混入默认安装体验。版本专属变化放在 Release 与发布记录，避免在首页重复维护构建号和历史迁移细节。

修改默认值时，同时核对首次运行、已有偏好、隐藏状态和截图说明。移动文档时检查相对链接、标题锚点、图片引用和代码块；更改文档不代表重新执行了应用测试。
