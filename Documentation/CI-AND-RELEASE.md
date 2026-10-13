# CI 与发布

本流程按提交选择检查范围。功能断言保持完整，发布仍复用目标 SHA 已验证的双架构产物。`build-dmg.yml` 负责检查与构建；`release.yml` 负责只读验证与最终发布。

## 执行档位

| 档位 | 触发条件 | macOS 任务 | 产物与发布资格 |
| --- | --- | --- | --- |
| `docs` | 已明确列入策略的普通文档 | 0 | 只运行离线规则和 Gate，无发布资格 |
| `pr-standard` | 既有普通业务 Swift 或对应测试 | 3：ARM 数据、界面、生产 App | 签名、架构、首次打开测试；无 DMG、无发布资格 |
| `pr-full` | 高风险、未知范围、强制完整的 PR | 6：双架构回归与 DMG | 两份候选包；PR 产物不能发布 |
| `main-full` | main 上影响构建或未知范围的提交 | 6 | 同 SHA 的双架构正式候选包 |
| `recovery-full` | 从 main 手动指定完整历史 SHA | 6 | 对同 SHA 重建完整候选包 |

所有档位执行固定工作流提交中的离线工具测试一次。原有 29 条直接回归入口、间接测试及断言保留：普通 PR 在 ARM 上执行全部，完整档位在 ARM 与 Intel 上各执行全部。诊断套件仍留在原数据组。

普通文档范围仅包括指定根文档、`Documentation/**/*.md` 和 `Documentation/validation/**/*.json`。`RELEASE_NOTES.md` 始终触发 main 完整构建。包配置、工作流、脚本、核心模块、资源、安装更新、宿主与单实例、Touch Bar、刘海和原生 HUD 改动触发完整 PR。新增源码/测试文件与其他未分类路径也触发完整检查。

分类实现集中在 `scripts/ci_policy.py`。PR 使用 base/head 的 merge-base 与 head 计算 diff；无法计算 diff 时选择完整档位。源码身份解析失败直接失败，禁止退回当前 HEAD。`ci_build_scope.py --before ... --after ...` 继续输出原有 `true`/`false`；工作流使用 `--event` 和 `--github-output` 获取档位和矩阵。

## 日常操作

正常开发提交 PR，查看稳定的 `CI Gate`。需要提前运行双架构检查时，给 PR 增加 `ci:full` 标签。增加或删除标签都会重跑分类；标签只增加检查。仓库变量 `CI_FORCE_FULL_PR=true` 可将所有 PR 恢复为完整检查。

同一 PR 按 PR 编号分组，新运行取消旧运行。main 提交按 SHA 分组；恢复按指定源码 SHA 分组；发布按标签分组，后三者不取消正在执行的任务。

Gate 使用只读 Actions API，核对同一个 `run_id` / `run_attempt` 的必需子任务集合，不能用矩阵聚合成功代替。PR 的 API head SHA 与实际构建的合并预览 SHA 分别绑定，不能混为同一个值。必需任务缺失、重复、失败、跳过、取消、未完成或无法获取完整状态都会失败。文档档位明确要求两个 macOS 矩阵跳过，源码任务成功。Gate 自身始终在前置任务结束后执行。

建议 main 的必需检查仅绑定 `CI Gate`，不增加第二人审批或合并队列。PR 事件不使用路径过滤，文档 PR 因而也能产生 Gate。启用分支保护属于独立仓库配置动作，应在 Gate 实际验证通过后执行；本分支不自动修改仓库权限或保护规则。

## 编译复用与计时

沿用已有 UI 共享静态模块，仅在同一任务内复用相同输入。idle-performance 与 design-layout 分别链接、分别启动进程、执行各自原有断言。源码内容与顺序、编译器、SDK 元数据、架构、环境、参数、依赖库/模块及共享工具参与指纹。没有跨运行二进制缓存。

仓库变量 `HUD_SHARED_UI_TESTS=0` 会恢复两组 UI 测试的独立编译。核心测试使用 `HUD_CORE_TESTS_ONLY=1` 缩小 SwiftPM 构建图；生产 App 始终由 `build-app.sh` 实际编译生产入口与 Helper。

完整档位只调用 `package-dmg.sh`，由它内部调用构建，避免先构建 App 再默认打包的重复编译。回归与打包的计时、失败记录上传为独立 `ci-timings-*` artifact，不能进入正式发布 ZIP。每份发布 artifact 仍只有 DMG、`SHA256SUMS.txt`、`manifest.json` 三个根文件，名称和 manifest 协议不变。

安装器诊断是 best-effort，生产 watchdog 保持 0.25 秒。为避免冷 Swift/dyld 启动与事件完整性断言相互干扰，正常安装器 fixture 的 watchdog 单独控制为 5 秒，真实 CLI 和全部原有断言保留；故障与故意挂起场景继续使用生产 0.25 秒期限，另验证挂起不会拖住安装。没有预热、自动重试或忽略失败。

## 正式发布

更新版本与说明，合并到 main；等待目标 SHA 完成完整双架构构建，再为该 SHA 创建并推送版本标签。标签工作流不重新编译，不选择 PR 产物，也不退回其他 SHA 或旧的成功运行。

发布端独立要求七个任务存在、唯一、完成且成功：

- `Validate source revision`
- `Regression (arm64, data)`、`Regression (arm64, interface)`
- `Regression (x86_64, data)`、`Regression (x86_64, interface)`
- `Build DMG (arm64)`、`Build DMG (x86_64)`

七个任务须来自选定运行的同一次尝试。API 若未返回任务的 attempt 字段，只能从明确的 attempt 专属查询端点绑定，不能从全历史任务集合推断。历史完整运行不需要额外存在新 `CI Gate` 名称。

仍验证版本、标签源码身份、两架构来源、校验和、manifest、ZIP 文件集合、过期状态、公开版本不可覆盖及草稿冲突。发布说明来自标签对应提交且保留原文；一级标题仅产生警告。不存在、不可读、来源不一致或版本不符仍失败。源码、构建和 Gate 保持只读权限；只有最终发布任务具有 `contents: write`。

## 恢复与回滚

发布上传或网络失败，原完整构建和产物仍有效时可重试发布。构建失败或产物丢失/过期时，从 Build macOS DMG 的手动入口选择 main，提供原始完整 40 位 SHA，重建两个架构，再重试原标签。恢复 SHA 必须是 origin/main 的祖先。

重建应重新运行全部任务；仅重跑失败任务可能混入上一 attempt 的任务或产物，不能取得发布资格。不同架构不得从不同 run/attempt 拼包。

分类不可靠时设置 `CI_FORCE_FULL_PR=true`；共享 UI 编译异常时设置 `HUD_SHARED_UI_TESTS=0`。离线测试跨平台有问题时恢复原生运行，不跳过断言。Gate 或发布规则异常时回退相应提交，保留未发布状态，不能固定返回成功。

## 验收证据

本次实施与测试结果见 [CI 发布优化验收记录](CI-RELEASE-OPTIMIZATION-2026-10-13.md)。跨架构性能应在同环境进行开关配对，每架构至少三对有效样本，保留失败与退化样本。记录排队到 Gate 的时间、macOS 任务执行总量及各阶段时间，不能把嵌套计时相加，也不能把任务数量减少当作耗时比例。

参考：[GitHub attempt 专属任务 API](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt)、[工作流并发机制](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)。
