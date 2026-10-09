#!/usr/bin/env bash
# Short optimized, isolated synthetic benchmark. No live logs, app launch or model tasks.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
EVIDENCE_DIR="$PROJECT_DIR/build/task-reliability/performance"
BASELINE_DIR="$PROJECT_DIR/build/task-reliability/baseline/source"
mkdir -p "$EVIDENCE_DIR"
benchmark_stage="prepare"
benchmark_started_at="$(TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z')"
# Every attempted run gets a fresh status, even if compilation or a benchmark fails.
# This prevents a previous successful exit code/report from masquerading as this run.
python3 - "$EVIDENCE_DIR" "$benchmark_started_at" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
metadata = {'schema': 1, 'status': 'running', 'started_at': sys.argv[2], 'timezone': 'Asia/Shanghai'}
(root / 'run-metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
(root / 'comparison.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
(root / 'exit-code.txt').write_text('running\n')
(root / 'README.md').write_text('# 任务状态短时性能对照\n\n本轮执行尚未完成。请先检查 `run-metadata.json` 和 `exit-code.txt`；当前没有可交付的本轮对照结果。\n')
PY
finish_benchmark_evidence() {
    benchmark_exit=$?
    trap - EXIT
    printf '%s\n' "$benchmark_exit" > "$EVIDENCE_DIR/exit-code.txt"
    python3 - "$EVIDENCE_DIR" "$benchmark_exit" "$benchmark_stage" <<'PY'
import datetime, json, pathlib, sys
from zoneinfo import ZoneInfo
root = pathlib.Path(sys.argv[1])
metadata = json.loads((root / 'run-metadata.json').read_text())
metadata.update(status='passed' if int(sys.argv[2]) == 0 else 'failed', exit_code=int(sys.argv[2]),
                final_stage=sys.argv[3], finished_at=datetime.datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(timespec='seconds'))
(root / 'run-metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
if int(sys.argv[2]) != 0:
    (root / 'comparison.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    (root / 'README.md').write_text('# 任务状态短时性能对照\n\n本轮失败，未产生可交付的完整对照。失败阶段：`' + sys.argv[3] + '`，退出码：`' + sys.argv[2] + '`。请检查本轮 stderr、退出码及源码校验记录；不要使用上轮残留数据作为本轮结果。\n')
PY
    exit "$benchmark_exit"
}
trap finish_benchmark_evidence EXIT
[[ -f "$BASELINE_DIR/Sources/TaskStatusMonitor.swift" ]] || { echo 'Missing immutable baseline fixture; run baseline preparation first.' >&2; exit 2; }
source scripts/hook-core-build.sh
CURRENT_CORE_FLAGS=("${HOOK_CORE_SWIFT_FLAGS[@]}")
CURRENT_CACHE="$SWIFT_MODULE_CACHE"
BASELINE_CORE="$BASELINE_DIR/.build/hook-core-standalone"
[[ -f "$BASELINE_CORE/libHookCore.a" && -f "$BASELINE_CORE/HookCore.swiftmodule" ]] || { echo 'Missing previously built baseline HookCore.' >&2; exit 2; }
swiftc --version > "$EVIDENCE_DIR/compiler.txt" 2>&1
uname -m > "$EVIDENCE_DIR/architecture.txt"
cp "$PROJECT_DIR/build/task-reliability/baseline/baseline-revision.txt" "$EVIDENCE_DIR/baseline-revision.txt"
# Record every Swift input, both linked static modules, and the compilation scripts.
shasum -a 256 HookCore/*.swift Sources/LimitModels.swift Sources/HUDPresentation.swift \
  Sources/TaskStatusAppearance.swift Sources/TaskStatusMonitor.swift Tests/TaskReliabilityBenchmark.swift \
  scripts/benchmark-task-reliability.sh scripts/hook-core-build.sh scripts/swift-module-cache.sh \
  "$BASELINE_DIR/Sources/LimitModels.swift" "$BASELINE_DIR/Sources/HUDPresentation.swift" \
  "$BASELINE_DIR/Sources/TaskStatusAppearance.swift" "$BASELINE_DIR/Sources/TaskStatusMonitor.swift" \
  "$HOOK_CORE_DIR/libHookCore.a" "$HOOK_CORE_DIR/HookCore.swiftmodule" \
  "$BASELINE_CORE/libHookCore.a" "$BASELINE_CORE/HookCore.swiftmodule" > "$EVIDENCE_DIR/source-sha256.txt"
benchmark_stage="compile-baseline"
swiftc -O -target "$(uname -m)-apple-macosx11.0" -module-cache-path "$CURRENT_CACHE" \
  -I "$BASELINE_CORE" -L "$BASELINE_CORE" -lHookCore \
  "$BASELINE_DIR/Sources/LimitModels.swift" "$BASELINE_DIR/Sources/HUDPresentation.swift" \
  "$BASELINE_DIR/Sources/TaskStatusAppearance.swift" "$BASELINE_DIR/Sources/TaskStatusMonitor.swift" \
  Tests/TaskReliabilityBenchmark.swift -o "$EVIDENCE_DIR/baseline-benchmark"
benchmark_stage="compile-current"
swiftc -O -D CURRENT_ENGINE -target "$(uname -m)-apple-macosx11.0" -module-cache-path "$CURRENT_CACHE" \
  "${CURRENT_CORE_FLAGS[@]}" Sources/LimitModels.swift Sources/HUDPresentation.swift \
  Sources/TaskStatusAppearance.swift Sources/TaskStatusMonitor.swift Tests/TaskReliabilityBenchmark.swift \
  -o "$EVIDENCE_DIR/current-benchmark"
shasum -a 256 "$EVIDENCE_DIR/baseline-benchmark" "$EVIDENCE_DIR/current-benchmark" > "$EVIDENCE_DIR/binary-sha256.txt"
benchmark_stage="measure-baseline"
TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z' > "$EVIDENCE_DIR/baseline-started-at.txt"
if "$EVIDENCE_DIR/baseline-benchmark" > "$EVIDENCE_DIR/baseline.json" 2> "$EVIDENCE_DIR/baseline-stderr.txt"; then benchmark_exit=0; else benchmark_exit=$?; fi
TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z' > "$EVIDENCE_DIR/baseline-finished-at.txt"
printf '%s\n' "$benchmark_exit" > "$EVIDENCE_DIR/baseline-exit-code.txt"
[[ "$benchmark_exit" == 0 ]] || exit "$benchmark_exit"
benchmark_stage="measure-current"
TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z' > "$EVIDENCE_DIR/current-started-at.txt"
if "$EVIDENCE_DIR/current-benchmark" > "$EVIDENCE_DIR/current.json" 2> "$EVIDENCE_DIR/current-stderr.txt"; then benchmark_exit=0; else benchmark_exit=$?; fi
TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z' > "$EVIDENCE_DIR/current-finished-at.txt"
printf '%s\n' "$benchmark_exit" > "$EVIDENCE_DIR/current-exit-code.txt"
[[ "$benchmark_exit" == 0 ]] || exit "$benchmark_exit"
benchmark_stage="verify-inputs"
shasum -a 256 -c "$EVIDENCE_DIR/source-sha256.txt" > "$EVIDENCE_DIR/source-verification.txt"
shasum -a 256 -c "$EVIDENCE_DIR/binary-sha256.txt" > "$EVIDENCE_DIR/binary-verification.txt"
benchmark_stage="write-report"
python3 - "$EVIDENCE_DIR" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
base, current = [json.loads((root / (name + '.json')).read_text()) for name in ('baseline', 'current')]
arch = (root / 'architecture.txt').read_text().strip()
measurement_times = {name: {edge: (root / (name + '-' + edge + '-at.txt')).read_text().strip()
                           for edge in ('started', 'finished')} for name in ('baseline', 'current')}
combined = {'schema': 1, 'status': 'passed', 'baseline': base, 'current': current,
    'baseline_revision': (root / 'baseline-revision.txt').read_text().strip(), 'architecture': arch,
    'compile_flags': ['-O', '-target', arch + '-apple-macosx11.0'], 'current_extra_flags': ['-D', 'CURRENT_ENGINE'],
    'measurement_times': measurement_times, 'timezone': 'Asia/Shanghai',
    'source_verification': 'passed', 'binary_verification': 'passed',
    'interpretation': 'Short optimized synthetic comparison. CPU includes the whole harness and RSS sampler and is expressed as a percentage of one core. Lower baseline CPU comes with skipped16MiB data and incorrect task count, so this is not a comparison at equal correctness. Whole-process RSS includes loaded frameworks. This is not a long-term energy or Intel hardware result.'}
(root / 'comparison.json').write_text(json.dumps(combined, ensure_ascii=False, indent=2) + '\n')
def number(value, digits=3):
    return '—' if value is None else f'{value:.{digits}f}'
def cpu(value, phase):
    return number(value[phase]['cpu_percent_of_one_core']) + '%'
def rss(value):
    return number(value['stress']['sampled_peak_resident_bytes'] / 1048576, 2) + ' MiB'
def correctness(value):
    return str(value['observed_remaining_count']) + ('，正确' if value['remaining_count_correct'] else '，错误')
fair = current.get('other_completes_before_giant_drains')
reader_bytes = current.get('production_bytes_read')
backlog = current.get('max_backlog_bytes')
readme = f'''# 任务状态短时性能对照

本轮测量时区：Asia/Shanghai。旧基线：{measurement_times['baseline']['started']} 至 {measurement_times['baseline']['finished']}；当前实现：{measurement_times['current']['started']} 至 {measurement_times['current']['finished']}。

使用实际生产 TaskStatusMonitor、`-O` 优化和 `{arch}-apple-macosx11.0` 目标编译，在独立合成目录中依次运行旧基线和当前实现。基线为 `{combined['baseline_revision']}`。两者均先确认两个显式 start，再追加一条精确 16 MiB 的有效 JSON 工具输出，同时完成另一个任务。没有读取用户日志、启动 App 或创建模型任务。

| 指标 | 旧基线 | 当前实现 |
| --- | ---: | ---: |
| 3 秒空闲窗口 CPU，占单核 | {cpu(base, 'idle')} | {cpu(current, 'idle')} |
| 8 秒压力窗口 CPU，占单核 | {cpu(base, 'stress')} | {cpu(current, 'stress')} |
| 压力窗口采样 RSS 峰值 | {rss(base)} | {rss(current)} |
| 另一个任务完成反馈延迟 | {number(base.get('other_terminal_latency_seconds'))} 秒 | {number(current.get('other_terminal_latency_seconds'))} 秒 |
| 16 MiB 输出读取收敛延迟 | 未暴露；旧实现跳读 | {number(current.get('giant_file_drain_latency_seconds'))} 秒 |
| 压力结束剩余运行数 | {correctness(base)} | {correctness(current)} |

当前实现剩余身份集合校验：{current.get('remaining_identity_set_correct')}；观测集合：`{json.dumps(current.get('observed_remaining_ids'), ensure_ascii=False)}`。最大积压为 {backlog:,} 字节，生产 reader 实际读取 {reader_bytes:,} 字节。另一个任务终态先于大文件读完交付：{fair}。

CPU 和内存覆盖整个 benchmark 进程，含运行时、只做聚合的观察 sink、20 ms RSS 采样以及已加载框架。CPU 百分比以单核为分母。写入夹具使用 64 KiB 流式块，不在内存构造 16 MiB 字符串；写入开销在 JSON 中单列。旧实现较低的压力 CPU 同时伴随跳过日志和错误归零，不能视为正确性相同的性能对照。

这是本机 {arch} 的短时合成测量。采样 RSS 是测量结果，不是正式内存上限；本结果不证明长期能耗、真实多聊天、实体 Intel 或完整工作日验收。

原始数据：`baseline.json`、`current.json`、`comparison.json`。编译器、架构、完整编译输入与静态模块哈希、二进制哈希分别保存在相邻文件。`source-verification.txt` 与 `binary-verification.txt` 核验了测量结束时输入和二进制未变；`run-metadata.json`、`exit-code.txt` 及两个实现各自的退出码记录本轮结果。可通过 `scripts/benchmark-task-reliability.sh` 重跑。
'''
(root / 'README.md').write_text(readme)
for name, value in [('baseline', base), ('current', current)]:
    print(name, 'remaining_count=', value['observed_remaining_count'], 'correct=', value['remaining_count_correct'],
          'idle_cpu_pct=', round(value['idle']['cpu_percent_of_one_core'], 3),
          'stress_cpu_pct=', round(value['stress']['cpu_percent_of_one_core'], 3),
          'stress_peak_RSS_MiB=', round(value['stress']['sampled_peak_resident_bytes'] / 1048576, 2),
          'other_terminal_latency_s=', value['other_terminal_latency_seconds'])
PY
benchmark_stage="complete"
