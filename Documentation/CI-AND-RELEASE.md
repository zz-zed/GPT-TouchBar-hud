# CI 与发布

日常操作分为开发检查、候选构建和公开发布。功能测试与原有断言保留；main 按需打包留到第二阶段，本轮仍为需要构建的 main 提交生成完整双架构候选产物。

## 开发检查

可以直接在 main 开发，也可以通过一个或多个 PR 合入 main。一次 push 中包含多个提交时，检查整个 push 的改动范围并构建末端 SHA；多次 push 分别检查各自 SHA。merge、squash、rebase 合并后都以实际 main 提交为准。PR 的测试产物不能用于正式发布。

PR 只自动覆盖目标分支为 main 的情况。打开、更新源码、重新打开 PR、改目标分支为 main、增加或移除 `ci:full` 标签都会重新检查。无关标签及仅标题/描述变化只运行轻量工具检查和名为 `PR metadata` 的说明任务，不产生新的 `CI Gate` 成功结论，也不取消正在进行的代码检查。缺失、未知或无法判断的事件信息保守地运行代码检查。面向中间分支的 PR 和合并队列不在本轮自动覆盖范围内。

同一 PR 的代码检查按 PR 编号分组，新运行取消旧运行；不同 PR 独立。main 按 SHA、恢复按指定 SHA、发布按标签分组，不取消正在执行的运行。

普通 PR 执行 ARM 全部回归及真实生产 App/Helper 构建、签名、架构验证和隔离的首次打开测试。高风险、未知范围或 `ci:full` PR 执行双架构回归及 DMG 构建。仓库变量 `CI_FORCE_FULL_PR=true` 可强制所有实际代码检查使用完整档位。

内部仍保留五个档位，集中在 `scripts/ci_policy.py`，避免范围判断和发布规则重复维护：

| 档位 | 条件 | macOS 任务 | 发布资格 |
|---|---|---:|---|
| docs | 仅普通文档 | 0 | 无 |
| pr-standard | 已分类的普通源码/测试修改 | 3：ARM 两组回归及 App 构建 | 无 |
| pr-full | 高风险、未知或强制完整 PR | 6：双架构四组回归及两份 DMG | 无 |
| main-full | main 上需要构建的改动 | 6 | 经发布验证后有 |
| recovery-full | 从 main 指定完整历史 SHA | 6 | 经发布验证后有 |

普通文档仅包括指定根文档、`Documentation/**/*.md` 和 `Documentation/validation/**/*.json`。`RELEASE_NOTES.md` 始终触发完整构建。新增源码/测试、未分类路径和无法取得 diff 也使用完整检查。

日常 `CI Gate` 使用 GitHub 原生 `needs`，要求源码任务成功、源码 SHA 与事件一致、策略输出完整，且实际传入的矩阵精确匹配档位的预期矩阵。需要执行的矩阵必须成功；只有明确的文档或元数据事件可跳过。Gate 不调用 Actions API，不需要 Actions 读取权限。它汇总本次依赖结果；逐个子任务及跨运行产物来源的严格证明由发布侧负责。

可在 main 采用并验证本工作流后，将 `CI Gate` 设为必需检查。分支保护、第二人审批和合并队列没有在本轮启用。直接 main push 的允许范围由仓库权限配置决定。

## 候选构建与测试入口

`scripts/ci_regression.py --suite data|interface` 是统一回归入口。清单保持第一轮已验证的 29 个脚本、原分组和原顺序；每个脚本仍由独立 Bash 进程执行，以原标签记录计时，失败保留日志及退出码并停止该组。重置预测运行时仍使用隔离核心构建目录。历史源码恢复使用当前工作流的可信入口，执行历史源码中的测试脚本。

沿用同任务内 UI 静态模块共享；idle-performance 与 design-layout 分别链接、分别启动进程并保留断言。共享输入指纹、核心测试构建图和两种原生架构保障不变，没有新增跨运行二进制缓存。`HUD_SHARED_UI_TESTS=0` 可恢复独立编译。

完整档位只调用 `package-dmg.sh`，内部完成生产构建；普通 PR 调用 `build-app.sh`。计时及失败证据上传为独立 `ci-timings-*` artifact。正式候选 artifact 仍仅包含 DMG、`SHA256SUMS.txt`、`manifest.json` 三个根文件，名称和 manifest 协议不变。

安装器生产 watchdog 保持 0.25 秒。事件覆盖 fixture 单独使用 5 秒，故障及故意挂起场景继续使用生产期限；保留实际 CLI、原有断言和有界挂起验证。

## 公开发布

直接 main 开发和 PR 合并均采用相同顺序：

1. 更新版本及发布说明，推送到 main。
2. 等待目标 SHA 的完整双架构候选构建成功。
3. 对该 SHA 创建并推送附注版本标签，例如 `git tag -a v0.1.43 <完整SHA> -m 'Release v0.1.43'`。
4. 标签工作流验证已有候选产物并发布。
5. 在 macOS 上运行现有公开验包工具，保留报告后完成发布验收。

发布和公开验包统一接受稳定 `vMAJOR.MINOR.PATCH` 版本、直接指向提交的附注标签。轻量标签、嵌套标签和预发布版本不进入本稳定发布链。本轮不改动已有远端标签或版本。

标签阶段不编译、不等待尚未完成的构建、不选择 PR 产物、不退回其他 SHA 或旧的成功运行。同时推送 main 与标签可能使发布先运行并拒绝；完整构建完成后，从 main 手动重试该标签即可。普通文档提交没有候选包，要发布该精确 SHA 时先执行完整恢复构建。main 后续继续前进，不影响仍是其祖先的目标提交发布。

标签 push 及其重新运行必须保持该事件的原始提交 SHA。标签在排队期间被移动，旧运行会拒绝；删除标签的事件不能发布。手动重试必须选择 main，解析指定标签的当前提交，并继续要求它是 main 的祖先。不要移动已公开版本的标签。

发布端独立查询 Actions API，要求以下七个任务唯一、完成并成功，且属于同一 run/attempt：

- Validate source revision
- Regression (arm64, data)、Regression (arm64, interface)
- Regression (x86_64, data)、Regression (x86_64, interface)
- Build DMG (arm64)、Build DMG (x86_64)

历史完整运行不要求额外存在新 `CI Gate` 名称。任务 attempt 缺失时仅可从明确的 attempt 专属端点绑定。继续检查标签对应源码、版本、两架构来源、manifest、摘要、ZIP 文件集合、产物有效期及草稿冲突；公开版本不可覆盖。发布说明取自标签提交并保留原文，一级标题只警告。只有最终发布任务具有 `contents: write`。

公开验包复用：

```bash
python3 scripts/verify-public-release.py v0.1.43 --repo zz-zed/GPT-TouchBar-hud
```

该工具仅下载证据、只读挂载 DMG，核对公开摘要、manifest、来源运行、App/Helper 架构、最低系统标识、签名和首次打开助手 CDHash，并生成 `verification.json`，不修改已安装 App。验收历史版本使用 `--allow-not-latest`。先保持本地标准入口；未新增 macOS 发布收尾任务，也未把它塞入 Ubuntu 发布任务。

GitHub Actions 使用自带 `GITHUB_TOKEN` 推送提交/标签不会触发后续 push 工作流。自动化提交或打标签应显式调度对应工作流，或使用适当的 GitHub App/PAT；本轮没有配置机器人凭据。

## 恢复、回滚与第二阶段

发布网络或上传失败而候选仍有效时，只重试发布。构建失败、产物过期或丢失时，从 Build macOS DMG 的手动入口选择 main，提供原始完整 40 位 SHA，重建两个架构，再重试原标签。目标必须为 origin/main 的祖先；重新运行全部任务，不能混合不同 run/attempt 的任务和安装包。

发布工作流的验证任务成功、publish 失败时，可以“只重新运行失败任务”：publish 下载验证任务实际输出的暂存包名称，即使当前 attempt 已递增。若验证暂存包超过一天已过期，重新运行发布工作流全部任务或从 main 手动重试；候选包仍有效时无需重建 macOS。候选构建工作流仍要求全部七个任务及两架构包属于同一 attempt，不能靠“只重跑失败构建任务”取得发布资格。

上传收到服务器确认前后发生网络中断，重试都先核对草稿已有文件的摘要，只补齐缺失文件。最终发布请求成功但响应丢失时，再次运行会拒绝修改公开版本；先用公开验包工具判断是否已经完成。若草稿已部分上传，随后又重新构建了候选包，新包与草稿摘要不一致时继续拒绝，不能覆盖已有文件。公开版本的 Latest 标记采用 GitHub `make_latest: legacy`，由创建日期与更高语义版本判定，避免迟到重试强制置顶旧版本；历史版本验包使用 `--allow-not-latest`。

分类异常可使用 `CI_FORCE_FULL_PR=true`；模块共享异常使用 `HUD_SHARED_UI_TESTS=0`。Gate 或发布检查异常时回退对应提交并保留未发布状态，不固定返回成功。

第二阶段先统计 main 候选包的发布利用率，再评估按需候选构建。届时同步区分检查运行和候选运行，并调整选择器；不能只删除 main 打包步骤而保留现有“同 SHA 最新匹配运行”的规则。可复用工作流只在出现真实编排重复时再抽取。

第一轮证据见 [原验收记录](CI-RELEASE-OPTIMIZATION-2026-10-13.md)；本轮变更与验证边界见 [修订验收记录](CI-RELEASE-REVISION-2026-10-13.md)。

参考：[CodexBar 原生汇总](https://github.com/steipete/CodexBar/blob/main/.github/workflows/ci.yml)、[GitHub 事件与分支过滤](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)、[GITHUB_TOKEN 触发规则](https://docs.github.com/en/actions/concepts/security/github_token)、[attempt 专属任务 API](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt)。

重试规则参考：[GitHub 重新运行的原始 SHA/ref](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)、[发布 API 的 Latest 策略](https://docs.github.com/en/rest/releases/releases#update-a-release)。
