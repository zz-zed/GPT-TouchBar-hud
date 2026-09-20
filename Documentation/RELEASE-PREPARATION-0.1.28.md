# 0.1.28 本地发布准备

2026-09-20。目标版本 **0.1.28 / Build 29**，沿用 0.1.27 / Build 28 的补丁版本与构建号递增方式。本轮包括菜单栏实际内容测宽、刘海 V2/窗口生命周期、默认关闭的原生 Hooks 实验及统一完成反馈；不是正式发布记录。

## 范围与提交

- 已验收的集成基线：`290d8952f73ed1d7f09f0981285dc187762bd38b`；实际接线代码：`0e267d258559f7577984a612d3fcd86637784ee8`。
- 发布准备分支：`release/0.1.28`；独立工作树：`/Users/didi/.codex/worktrees/release-prep-0-1-28/TouchBarCodexToken`。
- 原集成树、A/B/C 实施树和主分支保留。发布准备只更新版本和文档，未修改 Swift 生产代码或构建脚本。
- `RELEASE_NOTES.md` 为本次发布说明草稿；README 更新 Hooks 默认关闭、两种模式的完成反馈差异、多屏选择与当前构建方式。
- 原集成报告与清单是 0.1.27 / Build 28 阶段证据，保留原始哈希；0.1.28 产物使用独立清单。

## 主分支整合与发布边界

`CONTRIBUTING.md`“提交与 PR 说明”规定：“合并前请处理审阅意见，并确保分支能够通过当前 CI。”其“实现要求”还规定：“普通 PR 不要修改版本号、创建 Tag 或变更发布资产名称；发布版本由维护者统一处理。”本轮是用户明确授权的发布准备，因此可更新版本；尚未运行此次远端双架构 CI。

主任务早期指示“不直接合并主分支”，以及 `FINAL-INTEGRATION.md` 中未执行 merge/version bump 的记载，属于先前阶段范围与事实，不能解释成永久禁令。本轮明确要求独立任务完成提交和发布准备，未要求合并 main；因此完成独立分支即可，无需为此停工询问。本轮明确排除推送、标签、Release、部署/安装替换和真实 Hooks/信任设置变更。

现场只读 `git ls-remote origin` 核对：远端 main 与 v0.1.27 的 peeled 提交均为 `dd274b28f1f7487d447fad6bb62fd7ce3f9aad46`，未见 v0.1.28。远端主库为 `git@github.com:zz-zed/GPT-TouchBar-hud.git`；`legacy` 为旧库地址，未操作。

## 验证策略

已验收集成的 962 项联合检查、Display 7、设计 155、Touch Bar 布局 291、生命周期/焦点 34、任务状态 41 及 Hooks 隔离检查是本轮继承的代码证据，详见 [集成报告](FINAL-INTEGRATION.md)。版本和文档变更不重复无关 GUI、核心或性能测试。

本轮重新执行本机架构 App/DMG 构建，核对源码与包版本、主程序/helper 架构和最低系统目标、嵌套严格签名、DMG 校验与只读挂载内容、首次打开助手绑定及隔离副本检查，并生成新的全量包文件和 DMG 哈希。

## 尚待完成的发行步骤

1. 在后续授权下整合分支并推送主库，等待当前 main/PR 的 arm64、x86_64 CI。
2. 完成或明确接受下述硬件、宿主与兼容性验收限制。
3. 在后续发布授权下创建并推送匹配版本的 `v0.1.28` 标签；标签工作流会自动创建并公开 GitHub Release，不能当作仅创建草稿。
4. 验证 tag CI、两个架构 DMG、由 CI 生成的 `SHA256SUMS.txt`、Release 正式/最新状态；安装与真实 Hooks 启用另按授权执行。

## 保留的验收限制

- Hooks 默认关闭，真实宿主尚未信任和执行；启动覆盖缺口持续保留，不承诺全量任务数或精确零。started 早于 Hook 接收时初读保守未知，不承诺真实延迟或事件时序。
- 实体刘海接缝、透明角点击穿透、其他 App 全屏、多屏/Spaces、菜单自动隐藏、睡眠/锁屏/唤醒以及 Dock/Finder/Spotlight/更新重启仍待验收。
- 本地仅能准备 arm64 包。本机 Intel 交叉链接缺少 Swift 兼容库；未重复已知失败路径，也未生成 x86_64 或通用包。Intel CI、Intel 运行和实际 macOS 11 运行均未验证；minos 11 仅是编译链接目标。
- 无长期能耗结论。既有 12 秒静态样本中 Hooks CPU 高于 legacy，不能声称省电；未重跑性能或真实宿主探测。
- 沿用 ad-hoc 签名，未做 Apple Developer 签名或公证。

## 本轮完成的验证与材料

版本/构建输入提交：`55a1a6411dcc84a6d38274993b03f7219d98b50e`。其后收尾仅修改说明和验证记录，App 构建输入未变。主程序 SHA-256 随新版 Info.plist 的签名封装更新；helper 与已验收 C/集成版本字节一致。

| 验证 | 本轮结果 |
| --- | --- |
| `scripts/package-dmg.sh` | 完成优化编译、嵌套签名、arm64 DMG 打包 |
| 源码/包内 Info.plist | 完全一致；0.1.28 / Build 29、LSUIElement=true、最低系统声明 11.0 |
| 主程序与 helper | 均 arm64；实际 minos 11.0 / SDK 27.0；ad-hoc 严格签名通过 |
| `hdiutil verify` 与只读挂载 | 通过；DMG 内 7 个 App 文件哈希/大小与外部包全部一致，Applications 链接、首次打开助手及说明齐全 |
| 首次打开助手 | 绑定本次 App CDHash `6a4359ee4ed26ed13f8d44fda58c2fbfe621cd26`；语法检查通过；隔离测试覆盖取消、定向移除隔离属性、保留其他属性、重复执行、符号链接、哈希不匹配、异常参数和签名篡改；未启动真实 App |
| 原候选保留 | iteration-integration 中 7 个文件仍与原清单的哈希和尺寸完全一致 |
| 代码差异 | 相对 290d895，Sources/HookCore/HookHelper/scripts/Package.swift/.github 均无变化；只改版本与文档，因此未重跑无关全量测试 |
| 文档与交付检查 | Git 空白检查、说明链接、版本对应和本地 SHA256SUMS 核对通过 |

材料均位于本发布准备工作树：

- [发布说明](../RELEASE_NOTES.md)
- [App](<../build/GPT TouchBar HUD.app>)
- [arm64 DMG](../dist/GPT-TouchBar-HUD-0.1.28-arm64.dmg)，2,905,716 bytes
- [本地 SHA256SUMS](../dist/SHA256SUMS.txt)，只含 arm64；不替代后续 CI 的双架构校验清单
- [全量产物清单](validation/release-0.1.28-artifact-manifest.json)，已纳入 Git
- `build/release-evidence/package.log`、`package-verification.log`、`first-open.log`；这些生成日志保留在本地且被忽略

DMG SHA-256：`7026efe6af65979755b9e95064313082af29899956b4ed4392ae0f1dd1a506ce`。
主程序 SHA-256：`b34a314e2d177684a1e3971b3cf45f984c1688fa2c8e5f8a13c4afa5c45c3cdd`。
helper SHA-256：`32dd74e8236cf92ade4f325c4f3a2eaa31c445e049052bdef137069f6ca16d99`。

## 工作区清洁核查

检查口径为 `git status --porcelain=v1 --untracked-files=all`；另用 `git status --short --ignored` 明确列出保留的忽略内容。干净不表示目录中没有构建产物。最终提交后现场复核记录保存在 `build/release-evidence/worktrees-final.json`，不会将它自身的提交前快照冒充最终状态。

| 工作树 | 分支 / 保留基线 | 需保留的忽略内容 |
| --- | --- | --- |
| `/Users/didi/Desktop/codex-space/TouchBarCodexToken` | main / dd274b2 | `.build/` 编译缓存、`build/` 旧包与证据、`dist/` 既有发布产物、`Design/` 本地设计和交付记录 |
| `/Users/didi/.codex/worktrees/1a59/TouchBarCodexToken` | detached / 1a68cc5 | `.build/`、`build/`、`Design/`，A 的缓存、产物与设计资料 |
| `/Users/didi/.codex/worktrees/62bb/TouchBarCodexToken` | detached / 99d2e53 | `.build/`、`build/`、`Design/`，C 的缓存、产物与设计资料 |
| `/Users/didi/.codex/worktrees/6c27/TouchBarCodexToken` | detached / 57e4c23 | `.build/`、`build/`、`Design/`，B 的缓存、产物与设计资料 |
| `/Users/didi/.codex/worktrees/iteration-integration/TouchBarCodexToken` | detached / 290d895 | `.build/`、`build/`、`Design/` 与 Finder `.DS_Store`，原候选及证据保留 |
| `/Users/didi/.codex/worktrees/release-prep-0-1-28/TouchBarCodexToken` | release/0.1.28 | `.build/` 编译缓存、`build/` 新 App/验证日志、`dist/` 新 DMG/校验清单/发布说明副本 |

主工作树只更新被忽略的 `Design/iteration-next/DELIVERY.md` 和 `IMPLEMENTATION-TRACKING.md`，记录新入口和本轮结果，未改生产源码。未为清洁检查删除用户文件、丢弃现有修改或执行破坏性 reset。

本地准备已完成，无阻塞本轮交付的问题。正式发布尚缺本轮双架构 CI 和相关实机验收，并且本轮没有远端推送/标签/Release/安装或真实 Hooks 设置操作授权。后续发行需要按上面的步骤独立完成，不能将本地 DMG 视为已公开发布。
