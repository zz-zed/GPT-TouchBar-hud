# CI 与发布修订验收 · 2026-10-13

本轮按同类项目研究后的修订执行，沿用 codex/ci-release-policy 和草稿 PR #4。main 按需打包留到第二阶段；需要构建的 main push、历史恢复仍完整执行双架构回归及打包。此文记录提交前确认的实现与验证合同；最终远端运行和触发演练结果见 PR #4，以及工作区 build/ci-release-revision-validation/FINAL-VALIDATION.md。

## 实现

- 日常 Gate 改为原生 needs 汇总，不查询运行/任务 API、不接收 GitHub token。核对源码 SHA、档位输出及精确预期矩阵，缺失、取消、失败和非预期跳过均拒绝。发布侧仍严格要求同一 run/attempt 的七个必需任务和双架构产物，不依赖 Gate 名称。
- PR 增加 edited 事件，覆盖目标分支改为 main。ci:full 增加/删除继续重新检查。无关标签及仅标题/描述修改使用独立并发组，只做轻量检查，以 PR metadata 命名结果，不能取消代码运行或提供 CI Gate 成功结论。未知事件信息保守地检查。
- 发布解析与公开验包共享稳定三段版本及单层附注标签规则。本地 Git 解析和远端 API 解析均要求标签直接指向提交；轻量标签、嵌套标签、预发布版本拒绝。标签移动和丢失仍在写入前或发布前拒绝。
- ci_regression.py 集中维护 data/interface 的 29 个回归入口，保持第一轮已验证的全部脚本、分组、顺序、独立进程和计时标签。RESET_NEWS_CORE_DIR 隔离保留。历史源码通过当前可信工作流入口运行其自身脚本。专项分组 benchmark 同时识别旧内联入口和新统一清单。
- 操作文档按开发检查、候选构建、公开发布组织；现有 verify-public-release.py 纳入 macOS 本地只读验收，保存公开下载、摘要及 DMG 检查报告。没有新增发布后工作流、跨运行缓存、合并队列或机器人凭据。

## 提交前验证

- 本地 111 个测试方法通过；表驱动子场景另外覆盖不同事件、档位、矩阵缺失/重复、状态组合、同批次任务和产物拒绝。
- 真实临时 Git 仓库验证附注、轻量和嵌套标签；内存 GitHub 假服务验证轻量标签拒绝发生在任何发布写操作之前。
- 统一入口与 f047e99 中 29 个已验证脚本完全一致，基准清单保存于 Tests/Fixtures/ci-regression-layout-v1.json。实际失败命令退出 7，计时记录保留退出 7；模拟信号退出保留 137。
- actionlint 1.7.12 检查两份工作流通过；未提供 shellcheck，相关语法与静态约束单独核对。git diff --check 和 Shell 语法检查通过。
- 第一轮 UI 编译配对数据仍适用：本轮未修改模块共享实现、编译输入或 Swift 断言；不重复宣称新的性能比例。

## 完整验收与边界

本轮交付需要最终分支 SHA 对应的完整 PR CI 成功：源码、四个原生回归、两份 DMG、原生 CI Gate。核对两份实际 payload 的三个根文件、摘要、源码/run/attempt 身份，并保留六份计时证据和统一入口逐脚本执行记录。

触发演练核对无关标签/描述不会启动 macOS 或发出 CI Gate 成功，也不会取消在运行的代码检查；ci:full 和改目标分支回 main 应重新检查。任何演练运行失败均保留证据，不能用旧成功运行替代最终候选。

对已公开 v0.1.43 的验收是只读回归，既不创建 Release，也不修改安装目录。当前修改仍未进入 main；真实 main docs/standard 调度及历史 SHA recovery 使用新工作流的上线验证，需要后续明确合入后进行。它们的策略和拒绝路径在本轮离线测试中覆盖，不能表述成已完成真实 main 发布或恢复演练。

main 后续改为按需候选时，必须同步修改候选身份与选择器，避免“仅测试”的最新运行遮挡候选；本轮不实施该阶段。

## PR #4 再审查：协同与重试边界

发现并修复四项问题：发布失败任务单独重跑时，下载步骤错误地使用 publisher 的新 attempt 名称；标签 push 排队或重跑时，未绑定事件原始 SHA；旧草稿迟到发布时，强制 make_latest=true；候选部分重跑的成功任务会被 GitHub 复制并赋予新 attempt，原有编号检查未识别旧执行时间。暂存包名称现在由 verify 输出并供 upload/download 共同使用，标签 push 与删除事件显式校验，Latest 改为 GitHub 的 legacy 语义版本策略，候选七个任务还须实际执行于本 attempt 启动之后。

本地工具测试从 111 增至 122，全部通过。新增真实临时 Git 历史覆盖 main 连续提交、一次 push 多个提交、两次 PR 的 merge/squash/rebase 合并和末端文档提交；运行选择覆盖不同 main SHA 完成顺序倒置、无候选 SHA 和 PR 产物拒绝。发布离线编排覆盖暂存包在首次执行、只重跑 publish、全部重跑及新 run 中的绑定；标签移动/删除及非 main 手动重试拒绝；上传前后断线补传和最终发布响应丢失后禁止再次写公开版本。actionlint 与 Git 空白检查通过。

本次不触发真实 release.yml，不创建或修改标签/Release。发布重试以离线工作流绑定和内存 API 故障注入验证；新 main 调度仍待合入后验证。最终分支完整双架构 CI 及证据保存在 PR #4 和 build/ci-release-trigger-review/，不以旧 SHA 的成功运行代替本次验证。

实际单任务重跑演练使用旧 SHA 的元数据运行 38374107225（attempt 2），只重跑 PR metadata。依赖输出沿用并成功通过 Gate；源码任务在 attempt 2 API 中拥有新的任务 ID/编号，但时间仍是 attempt 1。原始 API 与日志保存在 build/ci-release-trigger-review/dependency-output-rerun*，该演练不执行 macOS 或发布。
