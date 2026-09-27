# 0.1.33 菜单栏重复入口修复

## 现象与判断

用户反馈 Intel 机器在多个会话执行任务时出现多个菜单栏入口。截图包含三个应用图标，分别显示 `--`、`5h 40%`、`5h 45%`。

检查 `v0.1.33` 和当前源码：`AppDelegate` 每个实例只创建一个 `NSStatusItem`，任务状态回调只更新已有入口。`main.swift` 没有单实例保护；自动启动脚本的 `pgrep` 检查和 `open` 之间也没有原子互斥。多个应用进程各自保留菜单栏和额度状态，能够解释截图。

已确认的是启动入口缺少互斥保护。尚未获取故障 Intel 机器的进程列表、启动路径及系统版本，因此“多会话具体通过哪条路径触发多实例”仍待现场核验，不能断言为 Intel 专属问题。

## 修改

- 新增 `Sources/SingleInstanceLock.swift`，以当前用户 Application Support 下的固定文件持有非阻塞 `flock`；同一用户的不同应用副本共享该锁。
- 在偏好迁移、`NSApplication` 和 `AppDelegate` 初始化前获取锁。已有实例持锁时，新进程正常退出；文件系统错误则记录错误并退出，不继续初始化界面。
- 锁由进程持有，正常退出和异常终止都会释放；保留锁文件，避免删除后出现不同 inode 各自持锁的问题。文件描述符设为 close-on-exec，避免后台子进程延长锁的生命周期。
- 新增真实子进程并发测试，并加入现有 arm64 / x86_64 构建工作流。

## 本地验证

| 检查 | 结果 |
| --- | --- |
| `bash scripts/test-single-instance.sh` | 92 项通过；5 轮各 12 个并发进程，均只保留一个持锁实例；涵盖正常退出、SIGKILL、子进程存活、无效路径及符号链接 |
| `bash scripts/test-task-status.sh` | 74 项通过 |
| `bash scripts/test-release-workflows.sh` | 64 项通过 |
| `swift build` | Apple Silicon 完整应用编译通过；有本机工具链路径警告 |
| `git diff --check` | 通过 |
| `HUD_TEST_ARCH=x86_64 bash scripts/test-single-instance.sh` | 链接失败；本机 Command Line Tools 的 Swift compatibility 库缺少 x86_64 slice。未完成 Intel 运行验证 |

以上测试未启动正式 HUD，未修改已安装应用或运行中的 HUD 进程。双架构 CI 仅新增测试步骤；本次仅提交本地修复，未触发远程构建、推送或发布。

## Intel 验收与旧实例边界

旧版 0.1.33 不持有新增的锁。首次验证修复版前，需要退出已有的全部 HUD 实例，再启动修复版；此改动不会主动终止仍在运行的同名旧版进程。

Intel 验收应确认：同时运行多个会话、重复打开应用后始终只有一个菜单栏入口；结束部分会话后，其余任务仍能刷新；应用正常退出或异常终止后可重新启动。若仍有重复入口，记录每个 HUD 进程的 PID、可执行文件路径、版本及 macOS 版本，以进一步区分旧版并存和其他触发路径。
