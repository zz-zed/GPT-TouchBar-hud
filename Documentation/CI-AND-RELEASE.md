# CI 与发布

应用构建检查使用 ARM job；正式版本由 ARM、Intel 两个原生架构并行构建、验包，再由 Ubuntu job 发布。生产 App 在每条架构链中只构建一次，发布直接使用该次运行的产物。

## 工作流入口

| 入口 | 工作 |
| --- | --- |
| Check：PR / main 代码提交 | 核心检查、ARM 生产 App 与 Helper 编译、签名、架构、版本和最低系统目标校验。 |
| Release：版本 tag | ARM 核心检查、双架构生产构建与原生 smoke、实际 DMG、历史升级与回滚、汇总发布。 |
| 本地专项 | 与改动相关的完整回归、图形交互和实体设备验证。 |

Check 处理目标为 main 的 PR，以及 main 推送；新提交取消同 PR 或分支的旧检查。文档与素材变更的触发规则由 `.github/workflows/check.yml` 定义，其余新增路径默认检查。若将工作流设为 required check，需要同时处理跳过时的成功状态，避免分支保护等待未启动的工作流。

Release 使用固定双架构矩阵和 `fail-fast: false`，一个架构失败不会取消另一个。相同 tag 的推送及手动恢复互斥且不主动取消。手动恢复从 main 选择已有 tag，发布在自身工作流内完成全部门禁。

## 测试与构建

`bash scripts/test-core.sh` 执行 HookCore、ResetNewsCore 测试，以及额度、任务、API 消费、更新和生命周期等应用层 fixture。公共 App 源码编译为可测试静态模块，每个 fixture 独立链接、运行。完整选择清单可用 `--list` 查看；具体边界见[测试覆盖清单](CI_TEST_COVERAGE.md)。

`bash scripts/test-core.sh --smoke` 使用已构建的 Helper，验证原生进程、IPC 和单实例行为，不重复编译整个应用测试模块。发布的两个架构都执行该检查。

生产构建使用显式 SDK、macOS 11 deployment target 和 ad-hoc 签名，GitHub runner 选择 Xcode 26.3。生产 Release 与测试 Debug 分别编译，不复用不同参数的产物。

核心检查与生产构建的优化依赖库使用相同 distribution 架构目录，输入指纹匹配时在同一 job 内复用。指纹包括编译器、SDK、完整 flags、源码与构建 helper；输入变化或编译失败会重新构建。应用测试模块独立启用 `enable-testing`，不会作为生产 App 发布。

打包使用已有 App，验包使用实际 DMG。两个架构都检查早期更新协议及代表性历史安装器的替换、失败回滚与清理。真实菜单、Touch Bar、刘海、多屏、休眠和性能仍按改动执行专项验证。

## 本地命令

```bash
make check      # 核心检查、当前架构生产 App、基本校验
make package    # 生产构建并打包
make verify     # 验证已有 DMG 和历史升级路径
make full       # 完整自动化回归，包含图形环境检查
```

Makefile 编排构建、测试与验包职责。领域测试、预览和诊断脚本可以用于定向验证；只执行脚本清单或语法检查，不代表对应原生测试已经通过。

## 发布与恢复

两个原生 job 各上传三个文件：DMG、`SHA256SUMS.txt`、`manifest.json`。manifest 记录源码 SHA、版本、Build、架构、仓库、run ID、文件大小和摘要；不使用 attempt 作为门槛，同一运行成功 job 的产物可以跨重试沿用。

publish 只下载当前运行两个架构的精确命名产物。校验后汇总两个 DMG、`SHA256SUMS.txt` 和 `build-manifest.json`，补齐草稿后公开。只有 publish job 具有 contents 写权限。

一个架构失败时重跑失败 jobs；仅发布失败时恢复发布。草稿中相同附件跳过、缺失补传、冲突停止。公开版本的相同附件可幂等确认完成，不能覆盖。中间 artifact 的保存期限由工作流定义；过期或缺失后需重新构建相应产物。

正式操作、发布说明格式和独立验包见[发布流程](RELEASING.md)。
