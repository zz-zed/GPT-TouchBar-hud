# 任务状态可靠性实施与验收记录

2026-10-08。本地实施工作树：`/Users/didi/.codex/worktrees/ac0f/TouchBarCodexToken`。Git 基线与本地 `origin/main` 均为 `2059fd678fc2eea86ee5ed1a517d1b5d383a59d3`。本记录对应未提交的独立试用实现，不表示正式安装或发布。

输入文件已从主工作区复制并校验：

| 输入 | SHA-256 |
| --- | --- |
| TASK-STATUS-RELIABILITY-PLAN-2026-10-08.md | aa678b7cce97bd9e47b25b7953a618f8a087fd2f181dd6bc610ee919e188233c |
| TASK-STATUS-IMPLEMENTATION-BRIEF-2026-10-08.md | 93e12a7376248b8aeff07b18e34509731b0842d536e2baf60ebdeac4c60db4f9 |

## 实现范围

普通模式的 `TaskStatusMonitor` 和实验模式的 `HookConnectionController` 均为适配器，使用 `TaskEngineController` → `TaskActivityEngine` 的同一生产实现。协调层只选择一个模式运行。Hooks 是加快发现的通知，不直接制造开始、完成或等待状态。旧 `TaskLogCursor` 已从生产移除；旧 resolver/reducer 保留用于历史兼容测试，不再由生产监测入口调用。

| 模块 | 责任 |
| --- | --- |
| LifecycleStreamDecoder | 逐字节校验 JSON 结构、UTF-8、转义和嵌套；只留下 session/event 类型、身份和时间戳；正文、工具参数及无关键不积累 |
| TaskJournalReader | 验证文件和 session 身份，按连续位置读取，区分 fetched 与 committed 位置；以捕获 EOF 为同步批次目标 |
| TaskInventory | ID 稳定键分页遍历、带重叠的近期发现、Hook 精确身份提示；按身份去重，独立记录遍历完整性 |
| TaskActivityEngine | 唯一生产状态转换与计数；同任务轮次顺序、历史与当前观察代次隔离；公平调度和批次发布 |
| TaskCheckpointStore | 把状态、完整记录断点、校验锚点和去重账本写进同一原子文件 |
| TaskEngineController | 主线程控制、后台串行 I/O、立即取消门禁、失效回调丢弃；模式切换共享串行顺序 |
| TaskObservationSink | 白名单观察值接口；没有另建诊断文件、导出包或设置页 |

普通模式保留中性 UI，不新增未知问号、诊断行或 tooltip。`TaskStatusSummary` 和 Hooks activity 保留同一个生产快照编号；完成反馈只改变装饰，不另算任务数。四个展示端在实际消费处发出 typed surface 事件，区分渲染请求、隐藏、未加载和不可用。这是应用逻辑消费证据，不是实体屏幕可见性的证明。

## 调度、内存和来源边界

默认单文件每轮 256 KiB、全局每轮 2 MiB、最多 32 个文件、目标工作时长 100 ms；读取器每 32 KiB 检查取消。100 ms 是调度预算，系统调用和单个块解析可能使实际耗时超过目标，性能记录单独报告测量。普通轮询间隔 1 秒，有积压或未完成发现时 50 ms 后继续。已知活动和待核对活动优先，同时为新文件及历史扫描保留公平份额。

256 KiB 不再触发跳尾或清状态。完整巨行在有限语义内存中解析：容器深度上限 256、允许字段单值 4 KiB、无关 key 最多保留 64 字节，正文值不保留。超过结构/语义限制记录固定问题，不推导无任务。相同事件在不同分块下，完整记录边界的结果一致。

数据库只读访问，使用绑定参数、忙等待和查询时限。按 ID 键排序遍历，并校验分页边界是否被删除或改写；近期 updated_at 查询只加快发现，不把可变排序的 OFFSET 查询当完整库存。库存容量、覆盖状态及来源分类均明确记录。已知活动/待核对不能因跌出一页或容量淘汰而丢失；容量达到上限时保留不完整证据，不声称已覆盖全部任务。

坏索引行逐行隔离，原始页边界与有效条目分开推进；整页坏行、超长或非法 UTF-8 身份以及分页边界变化不能阻塞后续有效任务。日志头来源与索引来源各自验证；只有受支持的 `cli`、`exec`、`vscode` 来源准入，不能用正常索引掩盖未知日志头来源。完整但损坏的记录使对应任务待核对，保留 lastKnown；普通正文或工具事件不能清除这个生命周期缺口。未写完的半行和读取预算积压不按损坏记录处理。

同宿主状态通道未接入。`TaskHostStateSource` 只定义准入边界，默认能力为 `continuousLogsOnly`。模型区分输入等待、审批等待和失败，但日志与 Hooks 不自行推定这些状态。`initialCoverageUnknown` 表示宿主范围不能确认，与日志索引遍历是否完成是不同维度。新起 sidecar、mtime、进程存活和工具/Token 活动不能充当宿主当前执行真值。

## 断点格式与恢复

默认文件：`$CODEX_HOME/.hud-task-state/checkpoint-v1.json`（未设置时为 `~/.codex/.hud-task-state/checkpoint-v1.json`）。目录 `0700`，文件 `0600`。格式 schema 1，文件最多 8 MiB，库存最多 8192 项，完成去重账本有容量限制。它包含内部身份和路径，因此不进入诊断导出，也不能用作可公开的采集包。

每项保存库存身份、来源、文件代次、device/inode、已完成换行位置、固定长度哈希锚点、已发布状态、当前捕获 EOF 批次的候选状态及轮次去重元数据。候选状态只处理已完整解码的记录；解码到一半的正文不持久化，重启时从 committedOffset 重读。状态和位置同一原子替换，文件 fsync 后再确认目录 rename 持久化。未变化的元数据不反复编码写盘；写盘失败保留内部恢复缺口。

日志轮转后尚未读到完整 session 头时，仍保存已知库存和降级后的最后状态，日志断点可以为空。重启后可独立于暂时不可用的索引重查已知路径，但身份验证和新观察代次的 start 门禁仍生效。断点编码前先计算保守容量预算，避免先分配超大 JSON 再检查 8 MiB 限额；超限保留已有文件并记录失败，不丢弃活动任务以强行保存。

恢复会检查允许路径、所有权、非符号链接普通文件、长度、边界换行与哈希锚点。轮转、截断、重写或坏缓存仅重建对应证据链。锚点覆盖文件前缀、session 边界和读取边界，适合检测正常日志变化；不等于整文件防篡改验证，不能保证发现保留锚点的历史内部改写加追加。

HUD 重启、模式切换、睡眠或宿主退出后，之前的 active 留作 lastKnown 并待核对。自动恢复库存和连续读取不需要用户操作；重新确认当前执行仍需本观察代次的明确 start，或未来经验证的同宿主状态。完成历史不重播提示。旧 Hooks `state.json` 不导入为新引擎的当前执行，原文件不自动删除。

## 生产诊断接入

只读参考了诊断工作树的 `DIAGNOSTICS-TASK-TRACE-PLAN-2026-10-08.md`（SHA-256 `6ca6069bdfe74014eb475058af6bd2eb4de5b060105844908fd89753937f347b`）及当时的 `DiagnosticEvent.swift`（`0e5f2e0d1bc4462f5a8902b4a64098e9f6493198a53bc870d6f0b9040fa13192`）。其当时只有聚合 task 事件，尚无可直接复用的逐任务事件类型；本实现没有复制该工作树源码。

诊断模块实现 `TaskObservationSink.record`，在应用启动时将记录器连接至 `TaskObservationRelay.shared.connect(recorder)`。记录器由诊断模块保活，接口本身弱引用且线程安全；回调可以来自工作队列或主线程，必须有界、非阻塞。诊断关闭时断开 sink。此接口没有磁盘写入或网络操作。

| 观察事件 | 接入诊断的含义 |
| --- | --- |
| read | 匿名任务、文件代次、读取前后位置、committed 位置、捕获 EOF、实际字节与积压 |
| transition / issue / excluded | 状态前后、固定接受/拒绝/排除原因，不从批次统计反推单任务原因 |
| inventory | 分页覆盖和库存规模；覆盖缺口与已确认任务数分开 |
| snapshot / members | 同一快照编号下的聚合值与分页匿名成员清单，含页号、总页数和成员总量 |
| delivery | 主线程接收或失效丢弃，stage 区分 runtime 与 coordinator；不代表实体显示成功 |
| surface | 四个实际消费端收到的同一编号、逻辑数量及完成反馈变换、隐藏等固定原因 |

进程内匿名身份与快照编号独立于原始 thread/turn/path；无正文、标题、账号、工具名称或用量字段。下游应按成员页完整性处理记录丢失，不能从缺页数据声称全量成员已保存。格式映射应使用诊断模块新增的逐任务事件，不能把字节或任务身份塞入旧聚合计数字段。

## 旧实现失败证据

`scripts/test-task-reliability-baseline.sh` 从不可变 Git 基线提取原生产源码，并执行真实 `TaskLogCursor.read` 和异步 `TaskStatusMonitor`。输出位于 `build/task-reliability/baseline/`。该脚本故意返回非零，是修复前失败证据，不属于候选版本必须为绿色的回归套件。

- 明确 start 后运行数为 1；精确 601,826 字节有效 JSONL 输出后变为 0；同轮工具事件后仍为 0。
- 独立输入清单中的 33、65 个主任务，经真实 SQLite/生产 monitor 只得到 32。
- 7 项检查中 4 项失败。原 `TaskStatusMonitor.swift` SHA-256：`2682c573050d9c9de0938440bfced99d2edab413c058ad0a155a44ff2a98c463`。

新测试比较独立夹具的身份集合，覆盖生产读取、调度、恢复、协调与展示。旧 cursor 的直接 consume 检查迁移到新 reader/engine/生产运行器测试；未保留一个只在测试里运行的旧推算器作为成功依据。

## 验证和试用

自动化验证已经完成。结构化结果、源码摘要、失败与修复证据、产物哈希见 [验证记录](validation/task-status-reliability.json)。

| 验证 | 本轮结果 |
| --- | --- |
| test-hooks.sh | 90 个测试、12 个套件通过，含流式读取、库存、恢复、IPC、取消及既有安全回归 |
| test-task-status.sh | 44 项检查通过，含普通模式中性展示、内部健康状态及真实 monitor |
| test-task-reliability.sh | 196 项检查通过；比较独立真值身份集合，覆盖两种模式、1/3/8/33/65 任务规模、巨行、重启和模式切换 |
| test-hook-integration.sh | 默认关闭、打开设置不安装、未就绪/关闭状态和代次切换通过 |
| test-notch-hud.sh | 展示回归通过，含真实引擎快照贯通四个消费端；204,025 是包含重复几何采样的断言次数，不是独立测试用例数 |
| test-release-workflows.sh | 64 项检查通过 |
| 独立审查 | 已确认的索引、来源、编码容量、半头部恢复和坏记录缺口问题均修复并补测；本轮限定范围内无未解决的 P1/P2 |

冻结输入摘要为 `3e5aca14053da7860807f6ac8a0406f073c74495e48e38668d48e0befdaf29ee`，覆盖 234 个源码、资源、测试和构建输入；构建前后核对未变化。清单位于 `build/task-reliability/validation/source-manifest.json`。系统通知服务采用可注入依赖，展示夹具使用独立存储和关闭的通知配置，不调用正式 App 的启动流程。

独立试用 App：`/Users/didi/.codex/worktrees/ac0f/TouchBarCodexToken/build/task-reliability/trial-20261008-arm64.noindex/GPT TouchBar HUD.app`。保留基线版本号 `0.1.40`、Build `43`，仅为本地试用，不是新发布版本。arm64 主程序与 helper 的 ad-hoc 签名严格验证通过，Mach-O 与 Info.plist 最低系统版本均为 macOS 11.0；未启动该 App。

主程序 SHA-256：`801fd6b3d34efa407eecd8fd64bd9c1d28d542c00cbe35353d2ff7fd7c4bf631`。完整包文件摘要、helper 哈希及 CDHash 位于 `build/task-reliability/validation/artifact.json`。

可分发的本地 ZIP：`/Users/didi/.codex/worktrees/ac0f/TouchBarCodexToken/build/task-reliability/GPT-TouchBar-HUD-task-reliability-arm64.zip`，SHA-256 为 `f50c97dec6e882e6ccc770ee8fbf5980155054d32ad669acc1fa23a9114796e7`。已独立解压，逐文件哈希与原 App 一致，解压后的签名再次验证通过。

x86_64 构建未通过链接：本机 Swift 6.4 工具链的 CompatibilityConcurrency、Compatibility56 等兼容库只有 arm64/arm64e 切片。已保留 `build-universal.log` 与 `toolchain.json`，未改最低系统版本、未替换工具链，也没有生成或声称 Universal/Intel 可执行包。Intel 构建及实机验证仍待具备相应工具链的环境完成。

最终短时性能测量使用相同合成工作负载及优化编译，源码与二进制哈希校验通过。3 秒空闲窗口的进程 CPU 为旧版 0.587%、新版 0.848%；8 秒压力窗口为 0.702%、7.099%（占单核，含测试程序），采样 RSS 峰值为 11.45、12.02 MiB。新版读取完整 16 MiB 输出，保留独立真值中的运行任务；另一任务的终态约 1.027 秒交付，大输出约 5.100 秒读完。旧版跳过输出且错误归零，因此低 CPU 不能作为相同正确性下的优势。完整测量时间、实际字节、基线与哈希见 [短时性能记录](../build/task-reliability/performance/README.md)。这不是长期能耗或实体 Intel 结论。

真实设备验收清单：

- 在实际 desktop 宿主以 1、3、8 个独立主聊天逐项对照身份；子代理不重复计数。至少 20 轮并发、完成、中断和恢复，并一工作日持续对照。
- Intel macOS 15.8.1 故障机重做“升级后新任务出现 1 又消失”；保留宿主版本、实际进程路径、架构和应用哈希。
- macOS 11 实机、睡眠唤醒、仅重启 HUD、升级且 Codex 不退出；日志模式中的待核对状态按上述能力边界验收。
- 等待审批、等待输入、失败、静默超过 30 分钟及宿主崩溃；不能用日志缺失推定成功或精确零。
- 硬件 Touch Bar、多屏/刘海和隐藏窗口验证真实可见效果；本次自动化只证明逻辑消费与渲染请求。
- 长期 CPU、内存与功耗对照；短时间合成压力样本不能代替能耗结论。

本轮不安装或启动独立试用 App，不替换正式 App，不停止用户的 HUD/Codex，不修改 Hooks/信任/启动配置，不自动提交、合并、推送、打 tag 或发布。
