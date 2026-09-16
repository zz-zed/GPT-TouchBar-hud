## 改动说明

<!-- 用 2—5 句话说明改了什么，以及用户会感知到什么。 -->

## 背景与关联 Issue

<!-- 为什么需要这个改动？可使用 Closes #123 / Fixes #123。没有 Issue 时请直接说明背景。 -->

## 改动类型

- [ ] Bug 修复
- [ ] 新功能或行为调整
- [ ] Touch Bar / 菜单栏 / HUD 界面调整
- [ ] 数据解析或额度口径调整
- [ ] 性能或稳定性优化
- [ ] 测试、构建或 CI
- [ ] 文档或图片

## 验证结果

<!-- 勾选已执行的检查。未执行的相关检查请说明原因。 -->

- [ ] `scripts/build-app.sh`
- [ ] `scripts/package-dmg.sh`
- [ ] `bash scripts/test-app-migration.sh`
- [ ] `bash scripts/test-account-token-usage.sh`
- [ ] `bash scripts/test-token-usage.sh`
- [ ] `bash scripts/test-touchbar-layout.sh`
- [ ] `bash scripts/test-touchbar.sh`
- [ ] 实体 Touch Bar 验证
- [ ] 本 PR 只有文档改动，不需要运行应用回归

补充结果或未执行原因：

<!-- 例如测试数量、CPU 对比、实体设备现象、已知限制。 -->

## 兼容性

- macOS 版本：
- 处理器：<!-- Apple Silicon / Intel / 未验证 -->
- Touch Bar：<!-- 有 / 无 / 未验证 -->
- 宿主应用及版本：<!-- ChatGPT / Codex / GPT；不涉及可填写“不涉及” -->

## 截图或录屏

<!-- UI、Touch Bar 或图片改动必须提供；其他改动可填写“不涉及”。请先移除账号和隐私信息。 -->

## 隐私与安全检查

- [ ] 未提交密码、API Key、访问令牌、授权码、账号信息或完整会话日志
- [ ] 未修改 ChatGPT / Codex / GPT 或 macOS 系统文件和安全设置
- [ ] 新增或变化的数据访问、网络请求及私有 AppKit 接口已在上文说明
- [ ] 不涉及新增数据访问、网络请求或私有接口变化

## 提交前检查

- [ ] 改动范围聚焦，没有混入无关重构或格式化
- [ ] 已为新行为或 Bug 修复补充相应测试，或说明无法测试的原因
- [ ] 用户可见行为、命令或文件名变化已同步更新文档
- [ ] 未在缺少维护者明确要求时修改版本号、创建 Tag 或调整发布资产名称
- [ ] 已阅读并遵循 [CONTRIBUTING.md](https://github.com/zz-zed/GPT-TouchBar-hud/blob/main/CONTRIBUTING.md)
