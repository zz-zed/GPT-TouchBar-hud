# 0.1.29 本地发布准备（阶段记录）

2026-09-20。目标版本 **0.1.29 / Build 30**。本轮只完成版本、发布说明、README 和本地 arm64 候选准备；不是正式发布记录，未推送分支、创建 PR、推送标签、创建或公开 Release，也未安装、替换或启动候选 App。

## 范围与提交分层

- 已接受的功能整合提交：`b5a5bbe1866e4d969fb0590117771445b798c815`，起点 main 为 `3007f8ae73daec9fcc2e15628a99bd18753eaffb`。
- 实际候选构建输入：`b9b485f009684c441e88b36cdec95b3c698fab0c`，包含 0.1.29 / Build 30、README 和 RELEASE_NOTES 更新。
- 构建后的文案收尾提交：`74b9f362121afb5ebdd056dfbd4e5220d79e8434`，只去除 README 与 RELEASE_NOTES 对会话审批历史的引用，没有修改 App、资源、脚本或候选产物输入。
- 发布准备分支：`release/0.1.29`；独立工作树：`/Users/didi/.codex/worktrees/release-0-1-29-prep/TouchBarCodexToken`。
- 功能范围是刘海完整外壳、短凹圆角/水平肩线/外圆角、独立原生调试，以及自动检查更新、持久状态、设置和菜单提醒。任务状态 Hook 改造继续暂停，本版没有把任务问号写成已修复。

主任务只读核对时，远端 main 为 `3007f8a`、latest 为 `v0.1.28`，未发现远端 0.1.29 标签、分支或 PR。本工作树没有再次执行远端写操作。`.github/workflows/build-dmg.yml` 对 `v*` 标签会在双架构构建后创建并公开 GitHub Release，因此标签推送不属于本地准备，必须等待后续明确授权。

## 证据分层

先前整合报告 `/Users/didi/Desktop/codex-space/TouchBarCodexToken/Design/iteration-next/NOTCH-UPDATE-INTEGRATION-REVIEW.md` 记录的是 `b5a5bbe` 功能整合证据：73 项更新策略检查、202,761 项刘海采样/集成检查、158 项设计集成检查，以及 arm64 分发构建和严格签名通过。这些结果早于 0.1.29 版本修改，不能冒充本次候选包装验证。

本轮从干净的 `b9b485f` 重新执行 `scripts/package-dmg.sh`，并针对生成的候选完成以下检查：

| 验证 | 0.1.29 本地结果 |
| --- | --- |
| 更新策略 | `bash scripts/test-app-update.sh`：73 项通过；安装脚本语法与非法目标拒绝通过 |
| App/DMG 构建 | `scripts/package-dmg.sh` 完成优化 arm64 编译、嵌套签名及 DMG 打包 |
| 源码与包内 plist | 源码、build App 和只读挂载 App 的 Info.plist 逐字节一致；0.1.29 / Build 30、LSUIElement=true、最低系统声明 11.0 |
| 签名与二进制 | build/mounted App 深度严格验证通过；HookEmitter all-architectures 严格验证通过；主程序与 helper 均为 arm64、minos 11.0 / SDK 27.0 |
| DMG | `hdiutil verify` 与本地 SHA256SUMS 通过；只读挂载后 App 的 7 个文件哈希与字节数全部匹配 build App；Applications 链接、首次打开助手和说明齐全 |
| 首次打开助手 | 绑定本次 CDHash `958748ee916376e769ace091044337f70f9f0d65`，无模板占位符；隔离副本覆盖取消、定向移除隔离属性、保留其他属性、重复执行、符号链接、哈希不匹配、异常参数和签名篡改，未启动真实 App |
| 工作区边界 | 未构建已知失败的本地 Intel 目标；未更改 Hooks、信任、全局偏好、真实安装或运行中应用 |

## 本地候选与哈希

- App：`/Users/didi/.codex/worktrees/release-0-1-29-prep/TouchBarCodexToken/build/GPT TouchBar HUD.app`
- arm64 DMG：`/Users/didi/.codex/worktrees/release-0-1-29-prep/TouchBarCodexToken/dist/GPT-TouchBar-HUD-0.1.29-arm64.dmg`
- 本地校验清单：`/Users/didi/.codex/worktrees/release-0-1-29-prep/TouchBarCodexToken/dist/SHA256SUMS.txt`，只含 arm64，不替代未来 CI 生成的双架构清单。
- 可提交清单：[release-0.1.29-artifact-manifest.json](validation/release-0.1.29-artifact-manifest.json)。
- 本地证据日志：`build/release-evidence/`，被 Git 忽略但保留在此工作树。

| 对象 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `GPT-TouchBar-HUD-0.1.29-arm64.dmg` | 2,942,146 | `aa352d4b6a1470f3be4157500707d9bc6b9cdd1e9db19da895f53672f5b19b7b` |
| `GPTTouchBarHUD` | 1,970,384 | `3b4a01d8920e85d1ccd7916ea42273334b5d3898c53e40922e56ec0e29394f8d` |
| `HookEmitter` | 334,128 | `32dd74e8236cf92ade4f325c4f3a2eaa31c445e049052bdef137069f6ca16d99` |
| 包内 `Info.plist` | 945 | `a8ecf39cbd670b2f12934ed9fe5da084ba0e7c37b74a8eb2bcd415fa154c1378` |

## 保留的验收限制

- 本地只生成 arm64。已知本机 Swift 兼容库缺少 Intel 切片，本轮未重复失败构建；x86_64 构建、签名与运行需要 GitHub Actions 的 Intel runner 补验。
- minos 11.0 是编译链接目标，不等于已完成真实 macOS 11 运行验收。
- 实体刘海接缝与黑色色差、圆角肩部、透明区域点击穿透、菜单自动隐藏、全屏、多屏、Space 和睡眠恢复尚未真机验收；synthetic 原生模拟不能替代该结果。
- 正式安装路径下的 30 秒调度、24 小时间隔、睡眠唤醒、GitHub 网络失败/限流和用户触发更新重启尚未端到端验收；自动更新测试使用隔离偏好、假网络和时钟。
- Hooks 真实信任、执行、任务准确性和问号状态改造不属于本次版本；没有省电或全量任务数结论。
- 候选继续采用 ad-hoc 签名，未做 Apple Developer 签名或公证。

## 后续发行步骤

1. 在用户后续授权下推送 release 分支或创建 PR，等待 arm64 与 x86_64 CI；本地 arm64 DMG不能替代 CI 产物。
2. 结合用户接受的风险边界完成或明确保留真机刘海、真实更新路径和兼容性验收。
3. 仅在正式发布授权后创建并推送匹配版本的 `v0.1.29` 标签；该动作会触发公开 Release，不能作为普通准备步骤执行。
4. 核对 tag CI 的两个架构 DMG、CI 生成的 `SHA256SUMS.txt`、Release 正式/最新状态，再按独立授权执行真实安装或更新验证。

本地准备已完成，没有需要扩大功能范围才能解决的阻塞。正式发布仍需双架构 CI 和上述实机/真实路径验收决定；本地候选不能表述为已公开发布。
