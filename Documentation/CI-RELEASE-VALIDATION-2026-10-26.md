# 自动化重构实测（2026-10-26）

本次验证在 GitHub 托管的原生 ARM、Intel macOS runner 和 Ubuntu runner 上完成。两个版本都使用新检出，没有恢复前次项目编译缓存；允许 runner 预装 Xcode。所有下表 job 均成功完成。

## 结果与证据

| 验证版本 | 日常 Check | 发布 ARM | 发布 Intel | Ubuntu 汇总 | 发布前关键路径 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 初版 `195a1f8` | 7 分 33 秒 | 7 分 34 秒 | 8 分 03 秒 | 10 秒 | 8 分 13 秒 |
| 核心库复用 `5c6b70a` | **5 分 06 秒** | **6 分 36 秒** | **6 分 30 秒** | **11 秒** | **6 分 47 秒** |

- 初版：[Check](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/40315672545)、[双架构发布前验证](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/40315667637)。
- 核心库复用版：[Check](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/40317591340)、[双架构发布前验证](https://github.com/zz-zed/GPT-TouchBar-hud/actions/runs/40317585473)。
- 对应源码：[195a1f864b42f559bd17a6d83b818612de9f5302](https://github.com/zz-zed/GPT-TouchBar-hud/commit/195a1f864b42f559bd17a6d83b818612de9f5302)、[5c6b70a85c0417e136261187e032edca3cb1624f](https://github.com/zz-zed/GPT-TouchBar-hud/commit/5c6b70a85c0417e136261187e032edca3cb1624f)。

计时取 Actions Jobs API 的 `completed_at - started_at`，包含检出、环境准备、测试、编译、验包、产物传输和 job 清理，排除每个 job 的 runner 排队。两架构并行，按 `max(ARM, Intel) + Ubuntu` 计算，因此第二轮为 `max(396, 390) + 11 = 407` 秒。失败或超时不计为达标。

以上两个样本来自不同提交，不能当作稳定性分布或 P95。第二轮日常 Check 命中 4～6 分钟目标；发布前路径已留出较大余量，但正式发布仍需观察下述未执行阶段。

## 第二轮耗时分解

| 阶段 | 日常 ARM | 发布 ARM | 发布 Intel |
| --- | ---: | ---: | ---: |
| 发布工具测试 | 7 秒 | 9 秒 | 在 ARM 执行 |
| 核心测试 | 2 分 43 秒 | 3 分 05 秒 | 在 ARM 执行 |
| 生产 App 构建 | 2 分 04 秒 | 1 分 52 秒 | 4 分 33 秒 |
| 原生 Helper 与单实例 smoke | — | 3 秒 | 4 秒 |
| 打包 | — | 6 秒 | 6 秒 |
| 实际 DMG 与历史升级路径验证 | — | 1 分 07 秒 | 1 分 25 秒 |

分阶段表未单列检出、环境准备及传输等少量开销；总时间始终使用完整 job 时间，不扣除这些步骤。

日常 Check 的生产构建日志在 11:49:46 UTC、发布 ARM 日志在 11:50:08～09 UTC 均明确输出 `Reusing optimized HookCore` 和 `Reusing optimized ResetNewsCore`。复用仅限同一 job 中配置和输入指纹完全匹配的两份优化依赖库；App 可测试模块仍单独编译，生产 App 与 Helper 保持原有编译参数。

## 已验证范围

- 36 项 Python 工具测试通过，包括构建/打包、核心库复用失效、发布恢复与冲突、公开版本读取、历史更新协议。
- HookCore、ResetNewsCore 的完整 SwiftPM 测试，以及原有任务、额度、更新、迁移、生命周期等 fixture、Notch 模型及单实例检查通过。断言归属见[测试覆盖清单](CI_TEST_COVERAGE.md)。
- ARM 与 Intel 均完成生产 App 和 Helper 构建、原生 Helper smoke、真实 DMG 打包与只读挂载验证。
- 两架构均通过 App/Helper 身份、来源指纹、版本、架构、签名和 macOS 11 部署目标检查。
- 两架构均通过首次打开脚本检查、v0.1.22 更新协议，以及 v0.1.38 安装器的替换、失败回滚与清理检查。
- Ubuntu 消费同一 run、同一源码 SHA 的两个架构产物，通过文件集合、版本和 SHA-256 校验，成功整理发布附件。
- `actionlint` 和 `git diff --check` 通过。

## 本次验证边界

实施时临时允许实施分支触发完整构建、验包和产物整理；仅执行 publisher 的准备模式，没有创建版本 tag、修改应用版本或公开 Release。验证后移除了这个临时触发条件和准备模式分支，正式工作流只接受版本 tag 或 main 上的已有 tag 恢复。

因此 **6 分 47 秒是发布前验证时间，不是已实测的完整公开发布时间**。实际向 GitHub Release 上传附件、读取并确认附件摘要、公开草稿的耗时，需要在首个正常版本发布时纳入同一口径；正常目标仍为 10～12 分钟，上限 15 分钟。相关恢复、同名冲突与幂等逻辑已有工具测试覆盖。

runner 上的签名和部署目标检查不能证明 macOS 11 真机运行。首次打开脚本使用受控 `open`，也不代表真实 GUI、Touch Bar、刘海、多屏或休眠唤醒已经通过；这些仍按改动执行真机验证。
