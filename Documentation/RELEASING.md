# 构建与正式发布

日常检查一个 ARM job；正式 tag 在 ARM、Intel 上并行构建并验证，再直接发布本次运行的产物。无需提前生成或查找 main 候选包。

## 日常检查

PR 和 main 代码变更运行 `check.yml`：核心快测、生产 App 与 Helper 编译、签名、架构、版本和最低系统目标检查。正常目标 4～6 分钟。纯文档处理见 [CI 说明](CI-AND-RELEASE.md)。

本地使用 `make check`；打包使用 `make package`；已有 DMG 使用 `make verify`；专项完整回归使用 `make full`。构建、打包与验包职责分开，打包及验包不会再次编译生产 App。

## 正式发布

1. 将版本、功能代码与用户发布说明合入 main。版本以 Resources/Info.plist 为准，说明来自该提交的 RELEASE_NOTES.md。
2. 固定待发布提交的完整 SHA，创建稳定版本 tag：`vMAJOR.MINOR.PATCH`。建议沿用附注 tag；轻量 tag 也可接受，嵌套 tag 和预发布版本不进入稳定发布链。
3. 在获得该版本发布授权后推送 tag。Release 工作流立即构建并验证这个提交的两个架构，不依赖另一条工作流的候选包。
4. 两个架构通过后，Ubuntu job 校验同一源码与摘要、上传草稿附件，完整后自动公开。
5. 首次迁移后的实际公开发布记录完整关键路径耗时；日后按需运行独立公开验包。

发布目标 10～12 分钟，完整成功执行上限 15 分钟；所有 runner 排队时间排除。按 `max(ARM, Intel) + publish` 计算，包含产物传输及实际公开。预算达标必须由真实运行证明，超时退出不算成功。

tag 必须指向 main 历史中的提交，版本与 Info.plist 一致，首次解析及公开前确认 tag 未移动。源码固定到 SHA，不在执行中跟随 main 前进。

两个原生 job 保留实际 DMG、架构、签名、最低系统目标、v0.1.22 早期更新契约和 v0.1.38 代表性安装替换/回滚验证。应用文件名、Bundle ID、DMG 命名与 SHA256SUMS.txt 协议继续兼容旧更新器。

## 正式发布说明规范

`RELEASE_NOTES.md` 与 GitHub Release 正文统一采用以下格式，按“新增功能 → 优化 → 注意事项”排序。正文不再添加产品名或版本号的一级标题：GitHub Release 名称和 App 更新弹框标题已负责展示版本名称。没有实际内容的栏目直接省略，不写“暂无”，也不为凑齐栏目添加内容。

```markdown
## 新增功能

- 本次新增的用户能力、使用入口或适用场景。

## 优化

- 本次改善的体验或修复的问题，以及用户可感知的变化。

## 注意事项

- 影响使用的默认设置、权限、兼容性限制或必要操作。
```

写作要求：

- 只写本版本实际交付、用户可感知的内容，每条直接说明功能或变化，简洁表达。
- Release 名称填写 `GPT HUD v版本号`；正文从二级栏目开始，不重复名称。
- 修复归入“优化”；必要的风险、限制及升级操作归入“注意事项”，不得为精简说明而隐去影响使用的信息。
- 不写迭代方案名称或编号、方案对比与选择、讨论与决策过程、评审结论、实现推导或调试经过。
- 不写测试项数、CI 运行结果、重试过程、提交 SHA、本地路径、构建进度或“已验收”等内部结论。
- 不将内部发布记录、工作日志或 PR 讨论直接复制为版本说明。上述材料独立保留，不自动追加到正式说明中。

例如写“优化刘海额度预览布局，缩短日期展示”，不写“采用 A 方案，经讨论确认右侧布局”；写“修复详情弹框超出屏幕的问题”，不写“补跑测试通过，确认弹框方案可发布”。

发布前人工逐项检查：内容是否属于本次版本、是否直接服务用户、是否有过程性叙述、是否遗漏必要注意事项。工作流只读取标签提交中的已审阅正文，不生成或附加讨论、测试及发布过程摘要。

已发布版本如需修正文案，须获得明确授权，仅编辑 Release 正文并同步本地说明；不移动标签、不替换安装包，也不重新运行发布来覆盖公开版本。这类授权后的文案更正可以与标签提交中的原始说明不同。

## 来源与产物

每个架构 artifact 只包含 DMG、SHA256SUMS.txt、manifest.json 三个根文件。元数据记录 schema_version、仓库、源码 SHA、版本、Build、架构、run ID 及文件大小/摘要；不记录 attempt，也不读取历史工作流资格。

发布只接受本工作流本次运行、相同源码和版本的两个架构，不拼接其他运行、提交或仓库的包。正式附件是两个 DMG、合并的 SHA256SUMS.txt 和 build-manifest.json。

原生构建只有 contents 读权限，publish 才有 contents 写权限；checkout 不保留凭据。使用 GITHUB_TOKEN，不增加个人 PAT。发布脚本默认只整理文件；必须显式 `--publish`，并满足版本 tag push 或 main 手动恢复上下文，才允许远程写入。

## 失败恢复

优先使用 GitHub Actions 的 **Re-run failed jobs**。一个架构成功、另一个失败时，沿用同一源码的成功 artifact；只有发布失败时，只恢复发布 job。固定 artifact 名称不含 attempt，重跑对应架构可以替换中间 artifact，不能替换已公开附件。

artifact 保留 30 天。如果成功产物过期或缺失，需要重建相应架构；完整恢复可从 Release 手动入口选择 main，填写已有 tag：

```bash
gh workflow run release.yml --ref main -f tag=v版本号
```

手动入口适用于包含本次迁移代码的 tag。旧的已公开版本不需要重建；历史公开附件继续支持独立验包。

草稿中摘要一致的文件跳过，缺失补传，冲突停止。若重新构建导致 DMG 字节变化，先核查并明确重置未公开草稿再恢复，不能混合新旧附件。正式发布请求成功但响应丢失时，再次运行会核对公开附件，相同即可确认完成。

公开资产冲突时拒绝覆盖。Latest 使用 GitHub `make_latest: legacy`，补发旧版本不强制抢占 Latest。

## 独立公开验包

在 macOS 下载四份公开附件并验证摘要、版本、架构、最低系统目标、签名与首次打开助手绑定：

```bash
python3 scripts/verify-public-release.py v版本号
```

结果保存在 build/release-evidence 下。历史版本可用 `--allow-not-latest`。工具兼容此前公开清单和当前精简清单，不依赖已过期的 Actions artifact；它不修改或启动已安装 App。

## 验证边界

本地 Python 测试覆盖版本、来源、文件集合、摘要、草稿恢复和拒绝覆盖等规则：

```bash
bash scripts/test-release-workflows.sh
actionlint .github/workflows/check.yml .github/workflows/release.yml
```

Linux 检查不能证明 macOS 构建、DMG 或安装器成功，必须取得两个原生 runner 的结果。分支迁移验证只准备产物，不公开 Release；公开写权限、上传和最终发布行为仍以正式运行结果为准。实际 macOS 11、真实 App 启动、实体 Touch Bar/刘海、多屏及休眠仍需相应设备验证。

参考：[工作流重跑](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)、[发布 API](https://docs.github.com/en/rest/releases/releases)。
