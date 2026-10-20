# 安装文件名迁移能力（默认关闭，尚未发布）

本分支实现新旧路径与双包能力，正式公开版本仍是 v0.1.46 / Build 49。没有通过本次工作启用自动迁移、发布新包或改变已有安装。`AppInstallationMigrationPolicy.automaticMigrationEnabled` 固定为 `false`；没有设置、环境变量或命令行启用入口。关闭时，启动、助手和就绪入口均在创建 driver 或访问迁移目录前返回。

## 安装与发行契约

- 新代码只接受 `/Applications`、当前用户 `~/Applications` 下的 `GPT TouchBar HUD.app` 和 `GPT HUD.app` 四个路径，仍拒绝路径链接和开发/DMG目录。
- 所有应用内更新继续选择 `GPT-TouchBar-HUD-<版本>-<架构>.dmg`，只提取包内 `GPT TouchBar HUD.app`，然后安装到当前会话精确的目标路径。
- 每架构增加独立 primary 包 `GPT-HUD-<版本>-<架构>.dmg`，包内只有 `GPT HUD.app`。compatibility 包仍只有旧名应用；两个包共享同次签名构建，但分别绑定首次打开助手与目标名称。
- 新 manifest schema 2 显式记录 kind 和 architecture；四份 DMG 与两份元数据采用精确集合校验。schema 1 历史发行验证与恢复仍保留。
- Bundle ID、可执行文件、App Support、单实例锁、LaunchAgent label 和 Hooks 身份不迁移。`legacy` 仍指原始 TouchBarCodexToken。

## 历史更新完成与候选交接

旧客户端从自己的 Bundle 复制安装器，不能由新包追溯修改。旧 ACK 对应单一 `context.targetPath`，UI可从ACK合成成功，但旧shell可能仍在`open`内。因此不能把ACK、UI成功、拿到应用锁或等待固定时长作为移动许可。

第一版只在旧路径完成正常启动后记录 pending 和系统 boot 身份。同一 boot 不迁移；以后自然系统重启的 boot 身份变化仅排除上个 boot 的进程，仍重新校验源身份/inode、目标、当前 boot 更新目录、其他安装和运行实例。未知或无法校验时继续旧路径，不要求再次更新或主动重启。这个 boot 策略已有代码与隔离测试，尚未完成真实跨系统重启验收。

生产 driver 与私有助手已经实现，但被默认关闭的总门禁保护：

1. 启动早期在应用锁内预检，拒绝碰撞、更新冲突和源变化；只在允许时复制完整的签名助手 bundle，退出当前启动实例；不把绑定 Info.plist 的裸可执行文件移出 bundle 后绕过验签。
2. 助手按 PID 加启动时间等待原进程结束；跨 boot 不把复用的同 PID 当作原进程。取独立维护锁后再次预检。
3. 隐藏复制候选并验签，以排他改名发布新目标；目标即使同 Bundle ID 也不能覆盖。先持久化候选 inode 证明，覆盖发布后日志未写的恢复窗口。
4. 明确新路径启动，并等待私有事务 nonce、目标、版本/签名身份、实际进程路径及启动时间的就绪回执。`open`返回成功本身不够。恢复时重新检查当前进程，不能复用上一 boot 的存活推断。
5. 只刷新精确认领的 LaunchAgent；裸助手显式读取稳定 Bundle 偏好域，保留 disabled 和 manual quit。候选启动不提前重写注册或清除退出标记。
6. 新路径就绪、启动指向处理完成后，旧副本按源 inode 和签名身份归档到事务专属隐藏目录，最后 commit。备份不自动删除。

若助手失败，在当前 boot 延期并保留可用副本；不杀可能已启动的候选、不把不确定状态当作成功。旧路径启动不会因预期延期条件反复退出。若 Finder 书签跟随已归档的旧 inode，受控入口只向已验证的新目标转交，不在备份目录初始化服务。外部 Dock/alias/第三方启动器是否跟随不作保证，也不改 Dock 私有偏好或普遍创建旧名 symlink。

## 维护锁与恢复

应用单实例锁控制菜单与服务实例；独立维护锁控制安装、迁移与恢复，不能互相替代。更新准备持锁，handoff 将同一 open file description 复制到 shell stdin；父进程退出后 shell 及同步后代继续持锁。原始 FD 保留 CLOEXEC；`open`启动边界将 stdin 重定向到 `/dev/null`，避免新应用或长期启动后代泄漏维护锁。关闭时只 close，不 unlink 锁 inode 或主动解除其他持有者的锁。

迁移日志采用 owner/mode/无链接检查、原子替换和同步写入。未完成迁移的持久 marker 也阻止新更新；helper 崩溃不能留下无人持有的开放更新窗口。恢复依据源/目标/备份实际身份与事务归属，允许重复执行；未知目标与用户另一份安装保持原样。不同目录的双安装、权限不足、符号链接、未知更新事务均为延期条件。

## 验证入口与边界

```sh
bash scripts/test-installation-maintenance.sh
bash scripts/test-installation-migration.sh
bash scripts/test-app-update.sh
bash scripts/test-app-update-progress.sh
```

前两项和原更新回归纳入正常及验证 CI。维护锁测试使用真实隔离进程，包含父退出、孤儿同步后代、原FD的CLOEXEC、成功/回滚释放及启动 stdin 隔离。迁移测试使用真实生产文件 driver、签名包、排他文件操作、原子日志、每阶段中断与恢复，以及碰撞/抢占/链接/更新阻塞；启动、就绪和 launchd 操作在本地测试中明确注入替身，不代表真实 LaunchServices、完整应用交接或真实系统重启通过。权限拒绝分支也有注入测试，仍需真实系统 ACL/权限矩阵验收。

历史 v0.1.22 仅有原模型/资产契约证据；v0.1.38 有真实 DMG 准备与隔离安装/回滚证据，其启动/回执使用替身。没有据此承诺所有历史版本完整安装链或真实用户自动升级。实际 macOS 11、实体硬件、Dock/alias、真实跨 boot 和启动交接未验收；保持默认关闭，不能把编译与夹具通过当作自动迁移上线许可。
