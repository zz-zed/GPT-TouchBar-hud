# 项目文件与文档导航

安装和日常使用从[项目首页](../README.md)开始。维护项目时，按下面的目录职责查找源码、测试、图片和历史记录。

## 目录分工

| 位置 | 内容与保留原则 |
| --- | --- |
| `Sources/` | macOS 应用源码。 |
| `HookCore/`、`HookHelper/`、`ResetNewsCore/` | 独立核心模块与辅助程序。 |
| `Resources/` | 应用图标、配置及打包所需资源。 |
| `Tests/` | 测试源码、夹具与历史升级兼容输入；不是构建输出。 |
| `scripts/`、`Makefile` | 构建、测试、打包、预览和维护入口。 |
| `.github/` | GitHub 工作流与贡献模板。 |
| `Marketing/` | 产品界面示例。 |
| `Documentation/` | 用户与维护说明。 |
| `.build/`、`build/` | 编译缓存、测试程序、本地 App、安装包与验证输出，Git 忽略。 |


## 使用与维护入口

| 文档 | 用途 |
| --- | --- |
| [USER-GUIDE.md](USER-GUIDE.md) | 界面、设置与日常操作。 |
| [DATA-AND-PRIVACY.md](DATA-AND-PRIVACY.md) | 数据口径、隐私与排查。 |
| [API-COSTS.md](API-COSTS.md) | 可选 API 消费统计。 |
| [UPDATING.md](UPDATING.md) | 安装更新与失败恢复。 |
| [UNINSTALL.md](UNINSTALL.md) | 卸载与本机数据清理。 |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 构建、回归和开发入口。 |
| [APP-ARCHITECTURE.md](APP-ARCHITECTURE.md) | 源码模块与职责。 |
| [RELEASING.md](RELEASING.md) | 维护者发布流程与验证边界。 |
| [CI-AND-RELEASE.md](CI-AND-RELEASE.md) | 持续集成与发布规则。 |
| [CI_TEST_COVERAGE.md](CI_TEST_COVERAGE.md) | 测试覆盖清单。 |
| [HOOKS-EXPERIMENT.md](HOOKS-EXPERIMENT.md) | 可选 Hooks 任务监测实验。 |
| [HOOKS-INTERFACE.md](HOOKS-INTERFACE.md) | Hooks 接入接口。 |
| [DIAGNOSTICS-M1.md](DIAGNOSTICS-M1.md) | 诊断与反馈操作及已知限制。 |


## 清理可重建缓存

```bash
bash scripts/clean-build-caches.sh --dry-run
bash scripts/clean-build-caches.sh --apply
```

`--apply` 仅在没有构建或测试运行时使用。脚本清理模块与 SDK 缓存，保留源码、测试日志、本地 App、安装包、设计资料与恢复备份；下次编译会重新建立缓存。
