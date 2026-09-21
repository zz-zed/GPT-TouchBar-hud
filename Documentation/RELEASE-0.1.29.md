# v0.1.29 正式发布记录

2026-09-21。**GPT TouchBar HUD v0.1.29 / Build 32 已正式发布，并设为 Latest。**

- 发布页：https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.29
- 源码提交：`f9d91d979dfe24805e77fd4c05b96c26046747ca`；标签：`v0.1.29`。
- 主分支 CI：https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/35564237740（双架构通过）。
- 标签 CI：https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/35564615249（双架构构建与发布通过）。
- 未替换或启动用户已安装的 App。

## 正式安装包

| 架构 | 字节数 | SHA-256 |
| --- | ---: | --- |
| arm64 | 3144558 | `a802146dcc1a7abd4749f85f713fb9cf3da3d757a41163da64fda28086a5059e` |
| x86_64 | 3225270 | `e0605197dfabf39ad15e4575bf45b8364b874421a33c789beb453fc9fcc7bc91` |

两个 DMG 均从公开 Release 下载，并与 SHA256SUMS.txt 和 GitHub 附件摘要逐一比对。DMG 完整性、只读挂载、版本及 Build、应用标识、主程序与 HookEmitter 架构、minos 11.0、严格签名、第三方声明、首次打开助手 CDHash 绑定与脚本语法均通过。

## 验证结果

| 检查 | arm64 | x86_64 |
| --- | ---: | ---: |
| 任务状态 | 41 | 41 |
| 更新策略及安装保护 | 73 | 73 |
| 既有刘海几何 | 193547 | 193547 |
| 原生呈现 | 418 | 418 |
| 实际呈现帧 | 137 | 89 |
| HookCore | 41 | 41 |

两种架构均通过真实 WindowServer 跨进程点击测试，以及首次打开助手的隔离副本回归。完整源码和附件对应关系见 [发布清单](validation/release-0.1.29-publication.json)。原始日志及下载包保留在本地 `build/release-evidence/publish-0.1.29/`。

## 发布过程修复

- `66cd0c9`：为自动更新重试常量显式声明 TimeInterval，兼容 CI Swift 编译器；重试时长不变。
- `f90c265`：原生动画测试显式覆盖减少动态效果开关，避免继承 runner 的系统设置。
- `f9d91d9`：真实点击测试等待接收器事件循环及 WindowServer 命中就绪；所有等待有界，每个用例仍只有一次真实点击。测试背景外扩 2 pt，保留 HUD 和四角测点，修复背景边缘像素取整。

早期标签运行 35562841184 的两次尝试均未完成 Intel 检查，Release 发布步骤被跳过。修复经双架构 main CI 验证后，在确认没有公开 Release 且远端标签未变的前提下，以指定旧标签对象的 force-with-lease 更新尚未发布的标签。旧标签对象保存于本地 refs/release-evidence/v0.1.29-before-ci-fix。

产品轮廓、内容间距、光晕、顶部锚点、动画和交互未因上述发布修复而调整。候选安装包记录继续保留，见 [发布准备记录](RELEASE-PREPARATION-0.1.29.md)；候选包与本次 CI 正式包不是同一产物。

## 尚未完成的真机验证

实体刘海接缝、黑位、全屏、菜单自动隐藏、多屏、热插拔及唤醒仍需真机验收。macOS 11 只校验了声明目标，未完成该系统的运行验收；正式安装路径中的自动检查、真实网络/限流与更新重启仍未做端到端验收。安装包采用 ad-hoc 签名，未经过 Apple 公证。
