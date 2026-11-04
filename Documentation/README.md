# 文档导航

安装和日常使用从[项目首页](../README.md)开始。本文列出用户说明、维护文档与目录职责。

## 使用说明

| 文档 | 内容 |
| --- | --- |
| [USER-GUIDE.md](USER-GUIDE.md) | 界面、设置与日常操作。 |
| [DATA-AND-PRIVACY.md](DATA-AND-PRIVACY.md) | 数据来源、保存方式、隐私与排查。 |
| [API-COSTS.md](API-COSTS.md) | 可选 API 消费接入与统计口径。 |
| [UPDATING.md](UPDATING.md) | 安装更新与失败恢复。 |
| [UNINSTALL.md](UNINSTALL.md) | 卸载与本机数据清理。 |
| [DIAGNOSTICS-M1.md](DIAGNOSTICS-M1.md) | 本机诊断与反馈。 |
| [TASK-STATUS-DIAGNOSTICS.md](TASK-STATUS-DIAGNOSTICS.md) | 任务状态的独立诊断工具及适用边界。 |
| [HOOKS-EXPERIMENT.md](HOOKS-EXPERIMENT.md) | 可选 Hooks 任务监测、配置与限制。 |

## 开发与维护

| 文档 | 内容 |
| --- | --- |
| [产品定位](../PRODUCT.md) | 产品目标、交互约定与能力边界。 |
| [贡献指南](../CONTRIBUTING.md) | 代码、验证和公开资料要求。 |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 从源码构建、定向回归与预览入口。 |
| [APP-ARCHITECTURE.md](APP-ARCHITECTURE.md) | 生命周期、状态流与呈现职责。 |
| [CI-AND-RELEASE.md](CI-AND-RELEASE.md) | 持续集成与发布流程。 |
| [CI_TEST_COVERAGE.md](CI_TEST_COVERAGE.md) | 测试覆盖与验证边界。 |
| [RELEASING.md](RELEASING.md) | 维护者发布操作、产物校验与恢复。 |
| [HOOKS-INTERFACE.md](HOOKS-INTERFACE.md) | Hooks 数据契约、模块与文件所有权。 |
| [NotchIsland/README.md](NotchIsland/README.md) | 原生刘海面板。 |
| [NotchIsland/UPSTREAM.md](NotchIsland/UPSTREAM.md) | 刘海实现的上游出处与许可说明。 |
| [NotchFusionDebug.md](NotchFusionDebug.md) | 刘海几何与调试入口。 |

版本变化见[发布说明](../RELEASE_NOTES.md)和 [GitHub Releases](https://github.com/zz-zed/GPT-TouchBar-hud/releases)。

## 目录职责

| 位置 | 内容 |
| --- | --- |
| `Sources/` | macOS 应用源码。 |
| `HookCore/`、`HookHelper/`、`ResetNewsCore/` | 核心模块与辅助程序。 |
| `Resources/` | 打包资源、配置和第三方许可声明。 |
| `Tests/` | 可重跑的测试源码与合成夹具。 |
| `scripts/`、`Makefile` | 构建、测试、打包与维护入口。 |
| `.github/` | 持续集成工作流与贡献模板。 |
| `Marketing/`、`assets/generated/` | 公开页面使用的成品图和演示素材。 |
| `Documentation/` | 稳定的用户说明与工程文档。 |

## 资料维护

公开文档应能脱离私人工作环境独立理解。保留使用方法、接口契约、必要兼容性限制和可复现检查；不纳入内部会话、原始工具输入、个人路径、执行交接或操作日记。

运行日志、诊断导出包、临时预览、制作输入和阶段报告保存在仓库之外。需要公开的测试结论应使用合成或脱敏数据，并限制在说明问题所需的范围。`Tests/` 中用于复现功能的夹具、许可证和必要上游出处继续保留。

移动或删除文档时同步检查相对链接、标题锚点与图片引用。忽略规则不自动停止跟踪已入库的文件，提交前应检查暂存文件列表和差异。
