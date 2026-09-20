# Hooks 实验本地交付与验证

2026-09-20。基线 `dd274b28f1f7487d447fad6bb62fd7ce3f9aad46`，v0.1.27 / Build 28；版本未改。

工作树：`/Users/didi/.codex/worktrees/62bb/TouchBarCodexToken`。完整接口与运行边界见 [接口说明](HOOKS-INTERFACE.md) 和 [实现说明](HOOKS-EXPERIMENT.md)。本次交付是默认关闭的实验代码与可审查本地包；没有启用真实宿主 Hook、改用户全局配置或信任记录、替换已安装 App、合并主分支、推送、打标签或发布。

## 已实现

- Swift 原生 helper → 私有 Unix socket → 纯 reducer → 定向只读日志核对 → 公共显示快照。用户无需 Node.js。
- `TaskStatusSummary.activity` 为 Hook 模式的唯一状态来源；菜单图标、任务标签和 Touch Bar 活跃标记采用同一个适配层。覆盖原因完整保留，未知不会被当成精确 0。
- 同 source/session 聚合、轮次顺序核对、Stop 暂留计数并复核、真实同轮续跑、旧轮 supersede 的可验证时间关系、子代理排除、重启/休眠/失联降未知、稳定完成身份与去重。
- 调度、记录、日志和连接上限；恢复或截断显式报告缺口。元数据调度表无容量拒绝后的残留计划，失联取消旧代际工作。resolver 留存和恢复输出的轮次元数据也在全文件范围内限制为 512。
- 独立默认关闭的设置入口；原生隔离能力预检、配置审阅、备份/合并/读回、精确条目清理，以及签名 helper 安装/升级/回滚/卸载边界。

## 检查结果

| 检查 | 结果 |
| --- | --- |
| `scripts/test-hooks.sh` | 40 项测试、7 个 suite 通过；包括重复乱序、跨轮次、Stop 续跑、阻止提交、子代理、中断、恢复、宿主异常、睡眠、漏事件、轮转、大日志、资源上限与隐私白名单 |
| `scripts/test-hook-integration.sh` | 默认关闭；打开设置不写配置/安装；明确未就绪与关闭状态；两种监测模式切换时拒绝旧回调，通过 |
| `scripts/test-hook-installer.sh` | 临时目录中实际签名校验、安装、升级、重复启用保留回滚记录、回滚、权限、仅卸载未修改的本工具文件，通过 |
| 原生 `HookHostPreflightSmoke` / Python discovery probe | 当前内置 `0.155.0-alpha.9.2` 独立实例发现四项，1 秒、同步、均 untrusted，错误 0；未执行 Hook、创建任务或写信任 |
| `scripts/test-hook-helper.py` | 打包后的 helper：25 项中性退出检查通过；额外用共享文件描述符位置确认超限输入实际读取不超过 1 MiB；wire 93 字节且无 prompt/reply |
| 现有任务状态回归 | 41 项通过，含新旧模型兼容、覆盖缺口图标、精确 0 不被过滤及关闭隐藏 |
| 账号 Token / 本地 Token | 53 / 18 项通过 |
| 更新 / 迁移 | 更新策略 38 项及 shell/目标检查通过；迁移 4 项通过 |
| Touch Bar 生命周期与焦点 | 34 项通过；没有并行运行 GUI 测试 |
| Touch Bar / 刘海 / 设计布局 | 291 / 573 / 155 项通过；GUI 检查串行，没有将焦点失败掩盖为通过 |
| 首次打开助手 | 隔离副本的取消、范围、属性保留、重复、符号链接、哈希、参数、篡改签名检查通过 |
| SwiftPM release | 构建通过；本机默认 swiftbuild 的产物最低目标为 12，未用它冒充支持 11 的分发包 |
| 显式 macOS 11 分发构建 | 优化编译和链接主程序与 helper 成功；实际包内两份二进制均 arm64、minos 11.0、SDK 27.0；严格签名验证通过 |
| shell/Python 语法、`git diff --check` | 通过 |

本机 CLT 的默认 swiftbuild 漏载 TestingMacros，首次测试构建失败。脚本现在显式加载工具链已有插件，完整重跑通过。原生 preflight 首次使用 Foundation 管道读取遇到等待读满，sample 定位后改为 poll + POSIX read；真实发现与静默进程时限测试通过。上述失败已修复，没有跳过测试。

## 性能与预算样本

原始数值保存在 [helper 进程样本](validation/helper-process-checks.json)、[监测对照样本](validation/hooks-benchmark.json) 和 [宿主发现结果](validation/runtime-discovery.json)。

- 打包 helper，接收器不存在，20 次：进程总耗时中位数 **5.32 ms**，P95 **14.01 ms**。无 ACK **213.23 ms**；不结束 stdin **508.31 ms**；均 `{}` 和 exit 0。此处包含进程启动及调度，不能将其当成内部 200/500 ms 预算的无开销测量。
- 同一进程依次运行旧模式与 Hooks，各 **12 秒**，32 份静态合成日志，每份 300000 字节填充加元数据，包含启动恢复：旧模式 CPU **0.100648 秒**；Hooks **0.269002 秒**。Hooks 读取 **8,388,608 字节**，有限恢复/复核读取 **224 次**。两者恢复语义不同；这只是短时固定输入样本。
- 这个样本不支持“已省电”的结论，也未覆盖长期稳态、活跃写入、实际宿主误报/漏报率或实际未知比例。隔离控制器场景在 2 秒测试等待窗口内收敛，不等于生产延迟 SLA 已验收。

## 包与兼容性

本地候选：`build/GPT TouchBar HUD.app`。包内主程序及 helper 的完整 SHA-256、大小、架构和部署目标见 [产物清单](validation/artifact-manifest.json)。使用现有 ad-hoc 签名策略，未新增公证或发行身份。

本机 x86_64 交叉编译失败：当前 CLT 的 `libswiftCompatibility56`、Concurrency 等缺 Intel slice，链接缺少对应 FORCE_LOAD 符号。未修改 Mach-O 版本字段、未提升产品最低系统版本、未声称 universal 包已通过。保留现有 arm64 / Intel CI runner 策略，补充 HookCore / HookHelper 触发路径及 helper 架构/签名检查；本轮没有推送触发 CI。minos 11.0 只证明真实编译/链接目标，macOS 11 实机运行尚未验证。

## 真实宿主阶段与集成待办

1. 用户主动应用配置并在宿主正常审阅信任后，验证真实桌面单/双主任务、提交被阻止、Stop 续跑、中断、子代理、老会话、中途启动、异常退出、休眠、漏事件及日志格式差异。此次只运行了隔离 discovery，没有真实 Hook 执行验收。
2. 明确验证宿主事件先后：首次读到的 `task_started` 若早于 Hook 接收时间，即使仅早 10 ms，本实现仍保持 unknown，直到有新的可归属执行证据。对应 fixture 已覆盖；不会通过任意扩大时间容差来把阻止的提交推成 active。
3. 启动覆盖目前始终含 `initialCoverageUnknown`，不会因为收到事件就升级为完整。历史/paginated-only/远程来源或无法关联轮次保持缺口；超过有限重试且无法建立文件观察的缺失日志，需要新 Hook 或显式恢复。
4. 主任务按 A → B → C 顺序在独立集成工作树审查接线。B 的 NotchTaskPresentation 消费 `summary.activityPresentation`；C 没有修改 HUDPresentation、刘海几何或菜单宽度。冲突重点为 AppDelegate 的监测生命周期/设置入口、Preferences 的实验入口、LimitModels，以及构建/测试脚本。
5. Intel CI、macOS 11 运行、真实宿主准确性和长期能耗仍未验证。上述限制保留默认关闭实验定位，不把本地实现完成等同于真实宿主验收或发布完成。
