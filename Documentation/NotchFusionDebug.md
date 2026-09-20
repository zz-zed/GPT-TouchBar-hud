# 刘海连续外壳：原生模拟与验证

本轮修正 v0.1.28 在硬件刘海底角两侧露出背景、摘要条起点形成台阶的问题。外壳从屏幕顶边开始，菜单栏高度内只覆盖 `auxiliaryTopLeftArea` 与 `auxiliaryTopRightArea` 之间的中央包围区；摘要、详情及交互仍在安全区下方。常规摘要新增高度保持 24 pt。更宽的内容从安全区下沿向下平滑过渡。

这里所有假刘海配置均为 **synthetic、未校准**。系统安全区不是硬件圆角的逐像素描述，本地模拟通过不代表真机视觉验收通过。

## 运行

在仓库根目录执行：

```bash
bash scripts/debug-notch-hud.sh
```

独立原生窗口提供：中文/英文、单双额度/长数字、内容宽度、三组屏幕参数、蓝/浅/深背景、收起/展开、动画进度滑块。预览使用正式 `NotchHUDView`、`NotchHUDGeometry` 和正式的缓动计算；假刘海由独立路径绘制。

“桌面顶部模拟”创建非激活的真实 HUD NSPanel 和完全穿透的假刘海窗口。可点击真实摘要展开/收起，在其他应用保持输入焦点时检验穿透。桌面模式的宽度和点击动画由正式控制器决定；预览的宽度强制值和进度滑块用于窗口内的确定性几何检查。

```bash
# 启动桌面顶部模拟，10 秒后退出，只清理自身窗口
bash scripts/debug-notch-hud.sh --desktop --seconds 10

# 生成原生合成截图后退出（短暂显示预览窗口以完成 AppKit 控件绘制）
bash scripts/debug-notch-hud.sh --snapshots
```

关闭调试窗口即可结束模拟。不会安装/替换正式 App，也不会关闭其他进程。此入口位于 `Tests`，不编入正式应用；编译时排除正式 `main.swift`、`AppDelegate.swift`、`AppUpdater.swift`，不启动 Hook、额度网络请求或自动更新。使用 UUID 隔离的语言偏好和固定假数据，退出清理本次偏好域。

## 自动验证

```bash
bash scripts/test-notch-hud.sh
bash scripts/test-design-layout.sh
HUD_BUILD_ARCHS='arm64 x86_64' bash scripts/build-app.sh
```

刘海测试保留既有布局、按钮、焦点、显示偏好、无刘海回退及全屏集合行为约束，并替换原先“整个窗口在安全区以下”的旧断言：

- 内容与交互在安全区以下；顶部中央装饰可见但不能命中；两侧菜单区域不能绘制或拦截。
- 独立圆角假刘海 + 正式 HUD 在蓝/浅/深背景合成，覆盖 1x/2x、24/32/38 pt 高度、等宽/略宽/宽内容和五个动画进度。逐点扫描硬件底部带状区域，不只检查中心连接点。
- 负对照保留旧式“仅从安全区下沿绘制”布局，在等宽条件下检查左右两处背景缺口都确实能被检出。这是旧几何的合成复现，不是真机旧版截图。
- 真正的 NSPanel 检查当前动画帧的 `ignoresMouseEvents` 与视图交互区域一致，并验证展开不抢前台应用焦点。
- 中文/英文、单双额度、长数字、极端内容自然换行/滚动、不同屏幕原点、非整数辅助区域边界。

输出位于被 Git 忽略的 `build/`，可由上述命令复现：

- `notch-fusion-before-synthetic.png`：旧式布局的缺口负对照。
- `notch-fusion-zh-dual-normal-0.0.png`：中文双额度收起。
- `notch-fusion-en-dual-normal-1.0.png`：英文双额度展开。
- `notch-fusion-en-dual-long-0.5.png`：长数字动画中间帧。
- `notch-debug-before.png` / `notch-debug-after-*.png`：独立入口截图。
- `notch-debug-window.png`：包含配置控件的原生调试窗口。

## 真机剩余验收

在用户的实体刘海 Mac 上，记录屏幕 frame、safeAreaInsets、左右 auxiliary areas、backing scale、显示缩放、摄像头兼容缩放设置与系统版本；保存软件截图和手机照片。

1. 检查照片里的左右蓝色楔形缺口是否消失、收起边缘是否仍有台阶；不同缩放和亮度下检查黑色色差及边缘。
2. 检查左右菜单、顶部装饰、透明肩角、底部圆角对应的底层菜单/标签页点击，确认没有抢焦点或吞点击。
3. 检查菜单自动隐藏、全屏暂隐/退出恢复收起态、用户主动隐藏、多屏拔插、睡眠/锁屏恢复。
4. 检查真实展开/收起中间帧及系统减少动态效果设置。

构建产物仅供后续真机检查；此任务不安装、不发布、不修改版本号。

## 本机验证记录（2026-09-20）

- 基线：`3007f8ae73daec9fcc2e15628a99bd18753eaffb`。测试机桌面为 1680 × 1050 pt，刘海均使用 synthetic 配置。
- `bash scripts/test-notch-hud.sh`：131,915 项断言通过，包含旧缺口负对照、像素合成、台阶边界、当前帧命中及既有展示集成。
- `bash scripts/test-design-layout.sh`：155 项既有设计集成断言通过。
- `bash scripts/debug-notch-hud.sh --snapshots`：独立 Swift 5 语言模式入口成功编译，输出原生截图。`NotchFusionDebug --desktop --seconds 40` 成功运行和退出，关闭自身模拟窗口。
- `bash scripts/build-app.sh`：arm64、macOS 11 目标构建及严格签名验证通过；本地 App 位于 `build/GPT TouchBar HUD.app`，未安装或启动。
- `HUD_BUILD_ARCHS='arm64 x86_64' bash scripts/build-app.sh`：arm64 编译成功，x86_64 链接失败。本机 Swift 6.4 Command Line Tools 的 `libswiftCompatibility56.a` / `libswiftCompatibilityConcurrency.a` 仅包含 arm64/arm64e，缺少 Intel 切片。未更改最低系统版本、构建脚本或发布流水线来绕过；Intel 构建须在具备兼容库的工具链/CI 补验。
- 无实体刘海验收结论；上述真机项目仍待执行。
