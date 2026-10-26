# CI 与发布

日常只有一个 ARM 检查 job；正式版本由两个原生架构并行构建、验包，再由 Ubuntu 发布。生产 App 在每条架构链中只构建一次，不查找此前 main 的候选包。

## 固定入口

| 入口 | 工作 | 正常执行目标 |
| --- | --- | --- |
| Check：PR / main 代码提交 | 核心快测、ARM 生产 App、签名/架构/版本/最低系统目标 | 4～6 分钟 |
| Release：版本 tag | ARM 核心快测；ARM/Intel 生产构建、原生 smoke、实际 DMG、升级与回滚；汇总发布 | 10～12 分钟，上限 15 分钟 |
| 本地专项 | 完整自动化回归与改动相关的真实设备验证 | 独立开发验证 |

Check 处理目标为 main 的 PR，以及 main 推送；新提交取消同 PR/分支的旧检查。Markdown、Documentation、Marketing 和 LICENSE 变更不触发日常编译，其余新增路径默认检查。版本和发布说明在正式 tag 流程中始终校验。如果以后把 Check 设为 required check，需要同时处理文档跳过的成功状态，不能让分支保护等待未启动的工作流。

Release 使用固定双架构矩阵和 `fail-fast: false`，一个架构失败不会取消另一个。相同 tag 的推送及手动恢复互斥且不主动取消。手动恢复从 main 选择已有 tag。发布自身完成全部必要门禁，不等待另一个工作流。

迁移期间使用实施分支的临时 push 触发完成双架构验证和产物整理，没有公开 Release。临时触发器在验证后移除，正式流程只接受版本 tag 和 main 上的已有 tag 恢复。

## 测试与构建

`bash scripts/test-core.sh` 保留 HookCore、ResetNewsCore 全部测试，并加入原有额度、任务、更新、生命周期等 fixture。公共 App 源码编译为一次性的可测试静态模块，每个 fixture 单独链接、单独运行。执行计划可用 `--list` 查看；断言归属见 [测试覆盖清单](CI_TEST_COVERAGE.md)。

`bash scripts/test-core.sh --smoke` 消费已构建的 Helper，验证原生进程/IPC与单实例操作，不编译整个 App 测试模块。发布两个架构都执行。

生产构建沿用显式 SDK、macOS 11 deployment target 和现有 ad-hoc 签名；GitHub runner 使用 Xcode 26.3。生产 Release 与测试 Debug 可以分别编译，不复用不同参数的产物。

核心快测与生产构建的两份优化依赖库使用相同的 distribution 架构目录；输入指纹匹配时在同一 job 内复用。指纹包含编译器、SDK、完整 flags、源码及构建 helper，变更输入或编译失败会重新构建。应用测试模块仍独立启用 enable-testing，不会用于生产 App。

打包消费已有 App；验包消费实际 DMG。两个架构都保留早期更新协议与代表性历史安装器的替换、失败回滚和清理。真实菜单事件、Touch Bar、刘海、多屏、休眠和性能专项按改动验证，不把模拟启动描述为真机成功。

## 本地命令

```bash
make check      # 核心快测、当前架构生产 App、基本校验
make package    # 统一生产构建，然后打包
make verify     # 验证已有 DMG 和历史升级路径，不重新构建
make full       # 完整可自动化回归；设备交互仍需真机
```

Makefile 只编排已有职责。原有领域测试、预览和诊断脚本仍可用于定向验证；旧分类、分组 gate 和历史候选选择器已移除。详细计时工具仅供手动诊断，不是发布门禁。

## 计时口径

所有 runner 排队时间都排除。job 实际执行中的检出、环境准备、编译、测试、验包、上传下载和正常清理全部计入。

`发布执行耗时 = max(ARM job 耗时, Intel job 耗时) + publish job 耗时`

工作预算为 ARM 8 分钟、Intel 10 分钟、publish 1 分钟，通常约 11 分钟，相对 15 分钟留约 4 分钟波动余量。job 超时只用于防挂死，取消或失败不能作为达标成绩。

迁移与首批正常发布观察冷项目缓存样本：新检出、不复用前次项目编译产物，允许 runner 预装工具链。每次只执行一轮；成功运行分别核算，失败恢复另记。超过 15 分钟仍是超预算，不能扣除网络传输等未约定项目。

迁移实测为日常 Check 5 分 06 秒、双架构发布前验证 6 分 47 秒；完整数据、计时方法及尚未公开 Release 的验证边界见 [2026-10-26 实测记录](CI-RELEASE-VALIDATION-2026-10-26.md)。

## 发布与恢复

两个原生 job 各上传三个文件：DMG、SHA256SUMS.txt、manifest.json。manifest 记录源码 SHA、版本、Build、架构、仓库、run ID、文件大小和摘要；不使用 attempt 作为门槛。同一运行成功 job 的产物可以跨重试沿用。

publish 只下载当前运行两个架构的精确命名产物。通过校验后汇总两个 DMG、SHA256SUMS.txt 和 build-manifest.json，先补齐草稿再公开。只有此 job 具有 contents 写权限。

一个架构失败时重新运行失败 jobs；仅发布失败则恢复发布。草稿相同附件跳过、缺失补传、冲突停止。公开版本相同附件可幂等确认已完成，绝不覆盖。中间 artifact 保留 30 天，过期后需要重建相应产物。

正式操作、版本说明和验证边界见 [发布流程](RELEASING.md)。此前优化记录作为历史记录保留，不再定义现行工作流。
