# v0.1.32 正式发布记录

2026-09-22。GPT TouchBar HUD **v0.1.32 / Build 35 已正式发布并设为 Latest**。

- [正式发布页](https://github.com/zz-zed/GPT-TouchBar-hud/releases/tag/v0.1.32)，面向用户的说明仅包含新增功能、优化和注意事项。
- 源码：`3c90c87f1e72f61ebbb990116427da47cf68ccc7`；标签：`v0.1.32`。
- [主分支 CI](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/35699932917)：Apple Silicon / Intel 均通过。
- [标签 CI](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/35700826664)：双架构构建及公开发布通过。

## 正式安装包验证

| 架构 | 字节数 | SHA-256 |
| --- | ---: | --- |
| arm64 | 3556067 | `47b16863c7203498c0a70f5d9807c0f0278e0d5f14cbe03836038c282ded98bc` |
| x86_64 | 3668076 | `6f6e6165024e89dcffab7f6ac76c680fd4f239f41e3c24df84a903be6127740a` |

两份 DMG 从正式 Release 下载，SHA256SUMS 与 GitHub 附件摘要、大小一致。DMG 完整性、只读挂载、版本 0.1.32 / Build 35、应用标识、主程序与 HookEmitter 架构、minos 11.0、严格签名及首次打开助手 CDHash 绑定均通过，挂载卷已卸载。CI 产物与先前本地候选属于不同构建，不要求两者二进制哈希一致。

## 验证证据

标签 CI 两端均通过任务状态 74、更新策略 73、预告运行时 202、宿主生命周期 22、刘海几何 194486、原生交互 429、Core 单测 96 项。原生呈现帧数 arm64 为 142，Intel 为 108；真实 WindowServer 点击穿透与首次打开助手保护场景均通过。

标签首次运行的 Intel 旧版动画完成断言失败；保留原始日志后，仅重跑失败任务一次，在相同源码及断言下通过。没有改写标签、跳过检查或降低断言要求。首轮日志不足以确定具体调度或可见性原因；此项作为测试稳定性记录保留，不放入面向用户的版本说明。

[机器可读发布清单](validation/release-0.1.32-publication.json) 保存对应关系和附件校验结果。原始日志与公开下载文件位于 `build/release-evidence/publish-0.1.32/`。未替换或启动用户已安装的 App；既有 Marketing 图片删除项未纳入发布提交。

## 验收边界

实际 macOS 11 运行、实体刘海屏完整场景及正式安装路径自动更新端到端仍未验收。安装包使用 ad-hoc 签名，未经 Apple 公证。
