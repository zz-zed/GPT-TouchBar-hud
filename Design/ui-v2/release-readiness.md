# v0.1.26 发布前准备

准备与发布日期：2026-09-17。当前状态：v0.1.26 已发布为最新正式版。

## 版本与范围

- 版本：0.1.26；Build：27。
- 发布提交：1c5e255；main、origin/main 与 v0.1.26 标签在发布时均指向该提交。
- 待发布范围：首次打开助手、Quiet 浮窗、Status-first 菜单与独立设置、Balanced Touch Bar、可读性与日期对齐修复、README 整体效果更新。
- 发布说明：仓库根目录 RELEASE_NOTES.md。发布工作流改为从标签对应的源码读取该文件，替代自动生成提交列表。

## 已完成验证

- 8 组回归共 627 项通过：迁移 4、账号用量 53、Token 18、任务状态 34、更新策略 38、Touch Bar 排版 291、生命周期 34、设计集成 155。
- 首次打开助手隔离副本专项通过。
- 本机 arm64 Release 构建、严格签名、DMG 完整性与二进制架构校验通过。
- 只读挂载 DMG：应用内版本为 0.1.26 / 27；签名有效；首次打开助手绑定正确 CDHash；说明文件及 Applications 链接存在。检查后已卸载挂载卷。
- Info.plist、发布说明版本一致；工作流 YAML 与 8 个内嵌 shell 块语法通过。
- 用户此前已确认界面迭代的实机效果可用；本轮没有重新执行真实账号或系统 Touch Bar 冒烟测试。
- 更正此前验证记录的合计笔误：原始基线实际 502 项，原生实现实际 627 项；各分项通过结果不变。

## 本地预检产物

- 安装包：dist/preflight-v0.1.26/GPT-TouchBar-HUD-0.1.26-arm64.dmg。
- 校验值：dist/preflight-v0.1.26/SHA256SUMS.txt，仅包含本地 arm64 包。
- 各项日志：dist/preflight-v0.1.26/。

这些文件是本地预检产物。正式发布流程会重新构建 arm64 和 x86_64 两个包，生成对应的完整 SHA256SUMS.txt。

## 正式发布结果

1. 发布准备提交已推送至 main；主分支 arm64 与 x86_64 构建、首次打开助手、签名、DMG 和架构校验通过。
2. v0.1.26 标签已创建并推送；标签流水线重新完成两个架构的构建与校验。
3. GitHub Release 已发布且标记为最新正式版：https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.26
4. Release 包含 arm64、x86_64 两份 DMG 和 SHA256SUMS.txt；公开资产摘要与校验文件一致。

正式附件 SHA-256：

- arm64：`74f7dd645c11db29ce0655834ed509782bd4a1a7e8135d9eca2012851d204fca`
- x86_64：`ec2245683455a0d4979ffbb29b0cb36ce9aa6d6fb10ca6dd55b96080a343fdd2`

远端 Intel 包已完成构建及自动校验；未单独在 Intel 实机或 macOS 11 实机启动应用。构建存在本机 Command Line Tools 搜索路径与 hdiutil 命令弃用提示，均未阻止构建和校验。
