# ChatGPT 更新后 HUD 数据读取修复

## 结论

ChatGPT `26.924.22138`（Build `11645`）将内置 Codex 从 `Contents/Resources/codex` 移至 `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。本机旧路径不存在，HUD `0.1.33` 因只识别旧路径而无法启动数据服务。

修复后的客户端已通过默认路径发现，成功读取并解码真实额度与账号 Token 数据。本次为本地修复，未提交、发布、安装或启动测试应用。

## 改动

- `CodexRuntimeLocator` 保持 ChatGPT → Codex → GPT 的宿主优先级，每个宿主内先查新版路径，再回退旧版路径。
- 候选必须存在、可执行且不是目录。无法发现程序时给出明确错误。
- 额度客户端和 Hooks 设置复用同一查找逻辑；更新原生和 Python 探测入口。
- 补充路径回归和真实接口检查，并将离线账号回归加入双架构构建工作流。
- 更新数据来源文档中的路径和排查命令。

## 验证

| 检查 | 结果 |
| --- | --- |
| `bash scripts/test-account-token-usage.sh` | 72 项通过，含新增 19 项文件系统路径检查 |
| `bash scripts/test-account-token-usage.sh --live` | 默认发现与初始化成功；额度类型解码成功；账号身份前后核验与 Token 统计成功 |
| `bash scripts/test-hook-integration.sh` | 通过；默认关闭、打开不安装、模式隔离正常 |
| `bash scripts/test-idle-performance.sh` | 36 项连接与空闲性能检查通过 |
| `python3 scripts/probe-hooks-runtime.py` | 新版 runtime 中发现四项 Hook，错误 0；未执行 Hook 或写入信任 |
| 原生 `HookHostPreflightSmoke` | 通过，同样只做隔离探测 |
| 独立子代理增量审查 | 未发现阻塞问题 |
| `git diff --check` | 通过 |

原生探测的可复现编译命令（仓库根目录，Bash）：

```bash
set -euo pipefail
source scripts/hook-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" \
  Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
  Tests/HookHostPreflightSmoke.swift -o .build/hook-core-standalone/HookHostPreflightSmoke
.build/hook-core-standalone/HookHostPreflightSmoke
```

## 测试包与边界

测试包：[GPT TouchBar HUD.app](../build/chatgpt-runtime-fix-20260927-180609/GPT%20TouchBar%20HUD.app)，保留版本 `0.1.33` / Build `36`，仅作为本地修复候选。构建包含工作区原有未提交改动，未丢弃或回滚这些内容。

同目录保存 `runtime-path-fix.patch`（仅本轮增量）、`source-inputs.json`（构建输入哈希）、`artifact-manifest.json`（产物哈希及验证状态）和 `build.log`。

Apple Silicon 主程序与 helper 编译通过。双架构构建在 Intel 链接阶段失败：本机 Command Line Tools 的 Swift compatibility 库仅含 arm64 / arm64e，缺少 x86_64。随后使用本次成功编译的 arm64 文件及同一源码快照的资源完成打包；helper 和应用的严格 ad-hoc 签名验证、arm64 架构检查均通过。没有调整部署目标或伪造 Intel 构建结果。

真实读取验证运行于本机 Apple Silicon。Intel 构建与运行、实体 Touch Bar / 刘海显示仍未验收。已安装的应用保持原样，实际界面恢复需使用修复包重新启动 HUD；现有启动失败状态无法仅靠“刷新额度”恢复。
