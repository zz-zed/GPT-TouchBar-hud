# 参与贡献

感谢你愿意改进 GPT TouchBar HUD。Bug 修复、macOS 兼容性、Touch Bar 布局、额度解析、性能、测试和文档类 Pull Request 都欢迎提交。

## 开始之前

- 小型修复和文档改进可以直接提交 PR。
- 新功能、依赖变更、数据口径调整或较大的界面改动，建议先创建 Issue 说明目标、方案和兼容性影响，避免重复投入。
- 修改常驻 Touch Bar 的私有 AppKit 接口前，请先说明目标 macOS 版本、回退行为和实体 Touch Bar 验证方式。
- 不要在 Issue、日志、截图或测试数据中提交账号信息、访问令牌、API Key、授权码或完整会话内容。

## 开发环境

- macOS 11 Big Sur 或更新版本。
- Xcode Command Line Tools，以及支持 Swift 5.8 的工具链。
- 运行真实额度检查时，需要在 `/Applications` 中安装并登录 ChatGPT、Codex 或 GPT；普通构建和大部分回归测试不要求登录。
- Touch Bar 不是普通构建的必要条件，但常驻显示和系统控制条共存仍需要实体设备验收。

## 建议工作流

1. Fork 仓库，并从最新 `main` 创建分支。
2. 使用范围清晰的分支名，例如 `fix/token-format`、`feat/menu-setting` 或 `docs/install-guide`。
3. 只修改解决当前问题所需的文件，避免混入无关格式化或重构。
4. 完成与改动风险相匹配的验证。
5. 向本仓库的 `main` 分支提交 PR，并完整填写 PR 模板。

本地构建：

```bash
scripts/build-app.sh
open "build/GPT TouchBar HUD.app"
```

生成当前机器架构的 DMG：

```bash
scripts/package-dmg.sh
```

## 回归检查

代码改动提交前，建议运行完整回归：

```bash
bash scripts/test-app-migration.sh
bash scripts/test-account-token-usage.sh
bash scripts/test-token-usage.sh
bash scripts/test-touchbar-layout.sh
bash scripts/test-touchbar.sh
```

按改动类型补充以下验证：

| 改动类型 | 需要说明的验证 |
| --- | --- |
| 额度或 Token 解析 | 覆盖缺失值、零值、异常值、账号切换和跨日场景；不要用本地日志统计冒充服务端账号口径。 |
| Touch Bar 布局 | 运行布局测试，并提供关键状态截图；至少覆盖“5 小时 + 周额度”“重置次数 + 周额度”和单额度状态。 |
| 常驻 Touch Bar | 说明 macOS 版本、实体 Touch Bar 结果、跨 App 切换、控制条展开/收起和关闭开关行为。 |
| 启动与迁移 | 验证旧设置、LaunchAgent、手动退出状态和默认隐藏 HUD；避免新旧进程同时运行。 |
| 性能 | 提供可复现的前后对比，包含观察时长、测试数据规模和 CPU/内存读数。 |
| 文档 | 检查命令、文件名、下载链接、图片和当前产品名称是否一致。 |

以下检查会访问本机登录态或短暂呈现系统级 Touch Bar，只有在明确需要时才运行，并在 PR 中说明结果：

```bash
bash scripts/test-account-token-usage.sh --live
bash scripts/test-touchbar.sh --smoke-system
```

涉及应用、资源或构建脚本的 PR，GitHub Actions 会分别构建和校验 Apple Silicon 与 Intel 安装包。远端检查通过不能替代实体 Touch Bar 的目视验证。

## 实现要求

- 保持 macOS 11 和 Swift 5.8 的现有最低兼容范围，除非 PR 已明确讨论调整原因。
- 不新增 API Key、密码或授权码配置，不上传本机会话日志，不绕过 ChatGPT / Codex 的现有登录机制。
- 不修改 ChatGPT、Codex、GPT 或 macOS 系统文件和系统安全设置。
- 涉及私有 AppKit 接口时必须保留运行时能力检查和安全回退，接口不可用时不能影响菜单栏和 HUD。
- UI 改动需兼顾有无 Touch Bar、不同额度组合、长文本和系统控制条共存。
- 新行为应尽量增加可重复的测试；修复 Bug 时优先加入能够复现问题的回归用例。
- 普通 PR 不要修改版本号、创建 Tag 或变更发布资产名称；发布版本由维护者统一处理。

## 提交与 PR 说明

- 每个提交保持单一目的，提交信息简洁说明结果；可沿用 `fix:`、`feat:`、`docs:`、`test:`、`refactor:` 等前缀。
- PR 需要说明问题背景、具体改动、验证命令、未执行的检查及原因。
- 界面或 Touch Bar 改动请附更新后的截图；存在视觉回归风险时同时提供修改前后对比。
- 兼容性或数据口径仍有不确定项时，请明确列出，不要把推测写成已验证结果。
- 合并前请处理审阅意见，并确保分支能够通过当前 CI。

提交贡献即表示你同意相关代码和文档按照本项目的 [MIT License](LICENSE) 发布。
