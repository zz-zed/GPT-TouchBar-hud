#!/usr/bin/env python3
"""Isolated macOS end-to-end checks for the distributable JXA probe."""
import datetime
import json
import pathlib
import sqlite3
import subprocess
import tempfile
import time

PROJECT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / "scripts/diagnose-task-status.command"
SOURCE = SCRIPT.read_text().split("<<'TASK_DIAG_JXA'\n", 1)[1].split("\nTASK_DIAG_JXA\n", 1)[0]
# Test only the supplied fixture home. Never inspect or alter the developer's logs/preferences.
SOURCE = SOURCE.replace("addHome(unwrap($.NSHomeDirectory()) + '/.codex','default');", "")
SOURCE = SOURCE.replace("var guiHome = command('/bin/launchctl',['getenv','CODEX_HOME']);", "var guiHome = {};")
checks = 0


def check(value, message):
    global checks
    assert value, message
    checks += 1


def event(kind, *, turn="PRIVATE-TURN-ID", stamp=None):
    return json.dumps({"type": "event_msg", "timestamp": stamp or datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "payload": {"type": kind, "turn_id": turn, "message": "PRIVATE-CONVERSATION-CONTENT"}}, ensure_ascii=False) + "\n"


def rows(path):
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # The currently written final line may be incomplete.
    return result


def wait_sample(report, index, process):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        for value in rows(report):
            if value.get("type") == "sample" and value["sample"] == index:
                return value["homes"][0]
        if process.poll() is not None:
            raise AssertionError("Probe exited before the requested sample")
        time.sleep(.03)
    raise AssertionError("Probe did not produce a sample within the test deadline")


def start(root, duration):
    report = root / "report.txt"
    report.touch()
    source = root / "probe.js"
    code = SOURCE
    if (root / "fixture-processes.json").exists():
        code = code.replace("var time = now(), running = apps();", "var time = now(), running = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding($.NSData.dataWithContentsOfFile(temporary + '/fixture-processes.json'), $.NSUTF8StringEncoding)));")
    source.write_text(code)
    process = subprocess.Popen(["/usr/bin/osascript", "-l", "JavaScript", str(source), str(duration), str(report), str(root), str(root), "fault"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return process, report


def finish(process, report):
    stdout, stderr = process.communicate(timeout=25)
    check(process.returncode == 0, "Probe exits successfully: " + stderr)
    values = rows(report)
    check(values[-1].get("completed") is True, "Completion footer is present")
    return values


with tempfile.TemporaryDirectory(prefix="task-probe-tests-") as directory:
    root = pathlib.Path(directory)
    (root / "sessions").mkdir()
    live = root / "sessions/本地任务.jsonl"
    bounded = root / "sessions/bounded.jsonl"
    invalid = root / "sessions/invalid.jsonl"
    old = "2020-01-01T00:00:00.000Z"
    live.write_text(event("task_started", stamp=old))
    bounded.write_text(json.dumps({"type": "response_item", "private": "PRIVATE-LARGE-TOOL-RESULT" * 20000}) + "\n" + event("task_started", stamp=old))
    invalid.write_text("not JSON\n" + event("task_started", turn="invalid / id") + event("task_started", stamp="invalid time")
                       + event("constructor") + event("task_started", stamp="October 8, 2026"))
    outside = root / "outside.jsonl"
    outside.write_text(event("task_started"))
    archived = root / "sessions/archived.jsonl"
    archived.write_text(event("task_started"))
    child = root / "sessions/child.jsonl"
    child.write_text(event("task_started"))
    missing = root / "sessions/missing.jsonl"
    db = sqlite3.connect(root / "state_5.sqlite")
    db.execute("CREATE TABLE threads(rollout_path TEXT, source TEXT, archived INTEGER, updated_at INTEGER, cli_version TEXT)")
    fixtures = [(live, "vscode", 0), (bounded, "cli", 0), (invalid, "exec", 0),
                (outside, "vscode", 0), (missing, "vscode", 0), (archived, "vscode", 1),
                (child, '{"subagent":"PRIVATE-SOURCE-ID"}', 0), (child, "PRIVATE-OTHER-SOURCE", 0)]
    for index, (path, source, archive) in enumerate(fixtures):
        db.execute("INSERT INTO threads VALUES(?,?,?,?,?)", (str(path), source, archive, index, "0.160.1"))
    db.commit()
    db.close()
    fake_apps = [{"role": "HUD", "pid": 111, "launchedAt": time.time() - 30, "version": "0.1.39"},
                 {"role": "Codex", "pid": 222, "launchedAt": time.time() - 60, "version": "26.1002.51308"}]
    process_fixture = root / "fixture-processes.json"
    process_fixture.write_text(json.dumps(fake_apps))
    process, report = start(root, 8)
    try:
        first = wait_sample(report, 0, process)
        check(rows(report)[0]["probeVersion"] == 2 and rows(report)[0]["stage"] == "fault", "Probe version and collection stage are recorded")
        check(any(t["category"] == "other" and not t["selectedByHUD"] and t["pathAllowedByHUD"] for t in first["recentIndex"]), "Recent excluded sources are visible as anonymous metadata")
        check(any(t["category"] == "subagent" and not t["selectedByHUD"] for t in first["recentIndex"]), "Excluded subagents are categorized without exporting raw source JSON")
        check(sum(t["selectedByHUD"] for t in first["recentIndex"]) == 5, "Recent index selection agrees with production candidates")
        check(first["selectedCandidates"] == 5, "Archived and non-root sources are excluded")
        check(first["independentModelRunning"] == 0, "Historical starts are not replayed as live")
        check(sorted(t.get("error", "ok") for t in first["tasks"]) == ["log_read_failed", "ok", "ok", "ok", "path_excluded_by_HUD"], "Unreadable and outside paths are distinguished")
        check(sum(t["skippedBytes"] > 0 for t in first["tasks"]) == 1, "Large logs use a bounded tail")
        check(all(t["readBytes"] <= 262144 for t in first["tasks"]), "Per-file read budget is respected")
        check(sum(t["invalidTurnID"] for t in first["tasks"]) == 1, "Invalid turn identity is diagnosed")
        check(sum(t["invalidTimestamp"] for t in first["tasks"]) == 2, "Invalid and non-ISO timestamps are diagnosed")
        check(all("constructor" not in t["events"] for t in first["tasks"]), "Unknown event names never invoke inherited object properties")
        check(sum(t["malformedJSON"] for t in first["tasks"]) == 1, "Malformed line is diagnosed")
        with live.open("a") as handle:
            handle.write(event("task_started"))
            handle.write(event("item_completed"))
        fake_apps[0].update(pid=112, launchedAt=time.time(), version="0.1.40")
        process_fixture.write_text(json.dumps(fake_apps))
        second = wait_sample(report, 1, process)
        second_sample = next(r for r in rows(report) if r.get("sample") == 1)
        check(second_sample["processChanges"] == {"hud": True, "codex": False}, "HUD restart is distinguished from unchanged Codex")
        check(second_sample["apps"][0]["version"] == "0.1.40", "Sample retains updated application metadata")
        check(second["independentModelRunning"] == 1, "A newly appended explicit start becomes running")
        check(sum(t["readBytes"] for t in second["tasks"]) < 262144, "Unchanged logs are not reread")
        with live.open("a") as handle:
            handle.write(event("task_complete"))
            handle.write(event("item_completed"))
            handle.write(event("token_count", turn=None))
        fake_apps[1].update(pid=223, launchedAt=time.time())
        process_fixture.write_text(json.dumps(fake_apps))
        third = wait_sample(report, 2, process)
        third_sample = next(r for r in rows(report) if r.get("sample") == 2)
        check(third_sample["processChanges"] == {"hud": False, "codex": True}, "Codex restart is distinguished from unchanged HUD")
        check(third["independentModelRunning"] == 0, "Late tool/token events do not revive completion")
        check(any(t.get("modelPhase") == "completed" for t in third["tasks"]), "Completion is retained")
        live.write_text("{}\n")
        fourth = wait_sample(report, 3, process)
        check(any(t.get("reset") and t.get("modelPhase") == "unknown" for t in fourth["tasks"]), "Truncation discards obsolete lifecycle state")
        values = finish(process, report)
        raw = report.read_text()
        for sensitive in [str(root), "PRIVATE-TURN-ID", "PRIVATE-CONVERSATION-CONTENT", "PRIVATE-LARGE-TOOL-RESULT", "PRIVATE-SOURCE-ID", "PRIVATE-OTHER-SOURCE", "本地任务"]:
            check(sensitive not in raw, "Report excludes private fixture values")
        check(values[-1]["homes"][0]["maxIndependentModelRunning"] == 1, "Footer reports the maximum observed live count")
        check(values[-1]["processChangeCounts"] == {"hud": 1, "codex": 1}, "Footer reports distinct process changes")
        check(values[-1]["stage"] == "fault", "Footer retains the collection stage")
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()

for mode in ["missing", "schema", "empty"]:
    with tempfile.TemporaryDirectory(prefix="task-probe-tests-") as directory:
        root = pathlib.Path(directory)
        if mode != "missing":
            db = sqlite3.connect(root / "state_5.sqlite")
            db.execute("CREATE TABLE threads(source TEXT)" if mode == "schema" else "CREATE TABLE threads(rollout_path TEXT, source TEXT, archived INTEGER, updated_at INTEGER)")
            db.close()
        process, report = start(root, 2)
        values = finish(process, report)
        home = next(r for r in values if r["type"] == "sample")["homes"][0]
        check(home["discovery"] == {"missing": "database_missing", "schema": "schema_incompatible", "empty": "ok"}[mode], "Missing, incompatible and successful empty results remain distinct")
        check(home["selectedCandidates"] == 0, "No substitute task data is invented")

subprocess.run(["/bin/bash", "-n", str(SCRIPT)], check=True)
print(f"PASS: {checks} standalone task diagnostic checks")
