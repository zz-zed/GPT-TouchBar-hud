#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/hook-core-build.sh
swiftc -O "${HOOK_CORE_SWIFT_FLAGS[@]}" Sources/LimitModels.swift Sources/TaskStatusMonitor.swift Tests/HookMonitoringBenchmark.swift -o .build/hook-core-standalone/Benchmark
fixture_dir="$(mktemp -d /private/tmp/hud-benchmark.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$fixture_dir" <<'PY'
import datetime,json,pathlib,sqlite3,sys,time
base=pathlib.Path(sys.argv[1]); home=base/'codex'; logs=home/'sessions'; logs.mkdir(parents=True)
(home).chmod(0o700)
db=sqlite3.connect(home/'state_5.sqlite'); db.execute('CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,source TEXT,archived INT,updated_at INT)')
for i in range(32):
 p=logs/f's{i}.jsonl'; session=f's{i}'
 header=json.dumps(dict(type='session_meta',payload=dict(id=session,source='vscode')))+'\n'
 event=json.dumps(dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),type='event_msg',payload=dict(type='task_started',turn_id='t1')))+'\n'
 p.write_text(header+'x'*300000+'\n'+event); p.chmod(0o600)
 db.execute('INSERT INTO threads VALUES(?,?,?,?,?)',(session,str(p),'vscode',0,int(time.time())))
db.commit(); db.close()
PY
.build/hook-core-standalone/Benchmark "$fixture_dir/codex"
