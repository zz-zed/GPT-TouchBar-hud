# v0.1.34 发布准备

2026-09-27。目标版本 **0.1.34 / Build 37**。发布提交包含 v0.1.33 之后的菜单分组、单实例保护、新版客户端内置 Codex 路径兼容、更新说明呈现、常驻空闲性能优化及相应回归。

## 本地验证

- 发布来源、产物校验和拒绝覆盖规则：64 项通过；版本说明无重复一级标题，`Info.plist` 格式正确，`git diff --check` 通过。
- 账号用量 72 项、更新策略 85 项、宿主生命周期 25 项、单实例 92 项、空闲性能与连接边界 36 项、菜单 30 项通过。
- 任务状态 74 项、重置预告运行时 202 项、刘海融合 203853 项、原生刘海呈现 437 项及 Core 单测通过。原生检查含真实 WindowServer 点击穿透；首次打开助手的取消、范围、重复执行与篡改防护通过。
- 独立 Apple Silicon 候选包位于 `build/release-candidate-0.1.34-arm64/GPT TouchBar HUD.app`。包内版本为 0.1.34 / Build 37，与源码 `Info.plist` 一致；主程序和 helper 均为 arm64，主程序最低系统标记为 macOS 11.0，严格签名验证通过。

## 正式发布门禁

将本次源码与说明作为同一提交推送 main；只有该提交的 Apple Silicon、Intel 两架构 CI 均成功后，才推送指向该提交的 `v0.1.34` 标签。标签工作流复用并校验同一份云端构建产物，再公开 GitHub Release。正式附件应为两份 DMG、`SHA256SUMS.txt` 和 `build-manifest.json`，发布后逐项核验来源、版本、哈希与 Latest 状态。

本地 Command Line Tools 不能链接 Intel slice，Intel 构建与运行以远端 CI 为门禁。真实 macOS 11 运行、实体 Touch Bar / 刘海全场景和自动更新安装端到端仍需对应设备验收。应用沿用 ad-hoc 签名，未经 Apple 公证。升级时须退出所有仍在运行的旧版实例。
