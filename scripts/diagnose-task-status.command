#!/bin/bash
# Standalone, read-only macOS probe. No Python, compiler, sudo or network required.
set -eu
umask 077
task_diag_seconds="${1:-120}"
task_diag_stage="${2:-unspecified}"
case "$task_diag_stage" in unspecified|fault|after-hud-restart|after-codex-restart|before-upgrade) ;; *) echo '采集阶段须为 fault、after-hud-restart、after-codex-restart、before-upgrade 或 unspecified。'; exit 2;; esac
case "$task_diag_seconds" in ''|*[!0-9]*) echo '用法：bash diagnose-task-status.command [监控秒数，2–600]'; exit 2;; esac
if [ "$task_diag_seconds" -lt 2 ] || [ "$task_diag_seconds" -gt 600 ]; then
    echo '监控秒数须在 2–600 之间。'; exit 2
fi
task_diag_report="$HOME/Desktop/TouchBar-task-diagnostics-$(/bin/date +%Y%m%d-%H%M%S)-$$.txt"
task_diag_tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/touchbar-task-probe.XXXXXX")"
trap '/bin/rm -rf "$task_diag_tmp"' EXIT
trap 'echo "监控已中断，已采集结果保留在：$task_diag_report"; exit 130' INT TERM
set -C
: > "$task_diag_report"
set +C
echo "正在监控 ${task_diag_seconds} 秒。请保持 HUD 运行，现在在 Codex 发起一轮新的本地任务。"
echo '期间不要重启 HUD，也不要切换任务监测开关。可按 Control-C 提前结束。'
echo "报告：$task_diag_report"
if /usr/bin/osascript -l JavaScript - "$task_diag_seconds" "$task_diag_report" "$task_diag_tmp" "${CODEX_HOME:-}" "$task_diag_stage" <<'TASK_DIAG_JXA'
ObjC.import('Foundation');
ObjC.import('AppKit');

function run(argv) {
    var seconds = Number(argv[0]), reportPath = argv[1], temporary = argv[2];
    var fm = $.NSFileManager.defaultManager, started = Date.now() / 1000;
    var budget = 262144, newline = $('\n').dataUsingEncoding($.NSUTF8StringEncoding);
    var report = $.NSFileHandle.fileHandleForWritingAtPath(reportPath);
    if (!report) throw Error('report_unavailable');
    function emit(value) {
        report.writeData($(JSON.stringify(value) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
        report.synchronizeFile;
    }
    function now() { return Date.now() / 1000; }
    function unwrap(value) { return value ? ObjC.unwrap(value) : null; }
    function version(value) {
        return typeof value === 'string' && /^[0-9][0-9A-Za-z.+_-]{0,47}$/.test(value) ? value : null;
    }
    // Only our child is terminated on timeout. Raw stdout/errors never enter the report.
    function command(path, args) {
        var capture = temporary + '/capture';
        fm.createFileAtPathContentsAttributes(capture, $.NSData.data, $.NSDictionary.dictionary);
        var output = $.NSFileHandle.fileHandleForWritingAtPath(capture), task = $.NSTask.alloc.init;
        task.launchPath = path; task.arguments = args;
        task.standardOutput = output;
        task.standardError = $.NSFileHandle.fileHandleForWritingAtPath('/dev/null');
        try {
            task.launch;
            var deadline = now() + 5;
            while (task.isRunning && now() < deadline) delay(0.05);
            if (task.isRunning) { task.terminate; output.closeFile; return {error:'timeout'}; }
            task.waitUntilExit; output.closeFile;
            if (task.terminationStatus !== 0) return {error:'command_failed'};
            var data = $.NSData.dataWithContentsOfFile(capture);
            if (!data || data.length > 65536) return {error:'output_limit'};
            var string = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
            var text = unwrap(string);
            return typeof text === 'string' ? {text:text} : {error:'decode_failed'};
        } catch (_) { output.closeFile; return {error:'command_failed'}; }
    }
    function sql(db, query) {
        var result = command('/usr/bin/sqlite3', ['-readonly','-json','-cmd','.timeout 50',db,query]);
        if (result.error) return result;
        try { return {rows:JSON.parse(result.text.trim() || '[]')}; }
        catch (_) { return {error:'sqlite_json_unavailable'}; }
    }
    function preferences(domain) {
        var values = $.NSUserDefaults.standardUserDefaults.persistentDomainForName(domain);
        function flag(key, fallback) {
            var value = values ? unwrap(values.objectForKey(key)) : null;
            var valid = value === true || value === false || value === 0 || value === 1;
            return {saved:valid ? Boolean(value) : null, effective:valid ? Boolean(value) : fallback};
        }
        return {taskStatusEnabled:flag('taskStatusEnabled',true),
            hookTaskMonitoringEnabled:flag('hookTaskMonitoringEnabled',false),
            persistentTouchBarEnabled:flag('persistentTouchBarEnabled',true)};
    }
    var hudID = 'io.github.zz-zed.GPTTouchBarHUD', legacyID = 'com.jackchen.TouchBarCodexToken';
    function apps() {
        var result = [], running = ObjC.unwrap($.NSWorkspace.sharedWorkspace.runningApplications);
        running.forEach(function(app) {
            var id = unwrap(app.bundleIdentifier), name = unwrap(app.localizedName);
            var role = id === hudID ? 'HUD' : id === legacyID ? 'legacy_HUD' :
                id === 'com.openai.codex' || name === 'Codex' ? 'Codex' :
                name === 'ChatGPT' || name === 'GPT' ? 'GPT_host' : null;
            if (!role) return;
            // Read metadata afresh: NSBundle caches can outlive an in-place upgrade.
            var info = app.bundleURL ? $.NSDictionary.dictionaryWithContentsOfURL(app.bundleURL.URLByAppendingPathComponent('Contents/Info.plist')) : null;
            var location = app.bundleURL ? unwrap(app.bundleURL.path) : '';
            var architecture = Number(app.executableArchitecture);
            result.push({role:role,pid:Number(app.processIdentifier),
                version:info ? version(unwrap(info.objectForKey('CFBundleShortVersionString'))) : null,
                build:info ? version(unwrap(info.objectForKey('CFBundleVersion'))) : null,
                architecture:architecture === 16777223 ? 'x86_64' : architecture === 16777228 ? 'arm64' : 'other',
                location:location.indexOf('/Applications/') === 0 ? 'system_Applications' :
                    location.indexOf(unwrap($.NSHomeDirectory()) + '/Applications/') === 0 ? 'user_Applications' : 'other',
                launchedAt:app.launchDate ? Number(app.launchDate.timeIntervalSince1970) : null});
        });
        return result;
    }
    var homes = [], roots = {};
    function addHome(path, origin) {
        if (typeof path !== 'string' || path.charAt(0) !== '/') return;
        var resolved = unwrap($.NSURL.fileURLWithPath(path).URLByResolvingSymlinksInPath.path);
        if (roots[resolved] !== undefined) { homes[roots[resolved]].origins.push(origin); return; }
        roots[resolved] = homes.length;
        homes.push({alias:'H' + (homes.length + 1),path:resolved,origins:[origin],cursors:{},
            aliases:{},aliasCount:0,selected:[],nextDiscovery:0,maxRunning:0,liveStarts:0,readFailures:0});
    }
    addHome(unwrap($.NSHomeDirectory()) + '/.codex','default');
    addHome(argv[3],'terminal_CODEX_HOME');
    var guiHome = command('/bin/launchctl',['getenv','CODEX_HOME']);
    if (guiHome.text) addHome(guiHome.text.trim(),'launchctl_CODEX_HOME');
    var system = command('/usr/bin/sw_vers',['-productVersion']);
    var machine = command('/usr/bin/uname',['-m']);
    var stage = argv[4] || 'unspecified';
    if (['unspecified','fault','after-hud-restart','after-codex-restart','before-upgrade'].indexOf(stage) < 0) stage = 'unspecified';
    emit({type:'header',probeVersion:2,stage:stage,startedAt:new Date(started * 1000).toISOString(),
        durationSeconds:seconds,osVersion:system.text ? version(system.text.trim()) : null,
        machine:machine.text && /^(arm64|x86_64)\s*$/.test(machine.text) ? machine.text.trim() : null,
        pollSeconds:2,discoverySeconds:10,readBytesPerFile:budget,
        scope:'independent_legacy_model_since_probe_start_not_HUD_memory',
        privacy:'No conversation, prompts, tool output, accounts, raw paths, IDs or raw errors exported.',
        guiProcessEnvironment:'not_inspected; launchctl environment is a candidate, not proof of HUD CODEX_HOME',
        preferences:'saved preferences, not direct inspection of HUD memory',
        homes:homes.map(function(home) { return {alias:home.alias,origins:home.origins}; })});
    function validID(value) { return typeof value === 'string' && /^[A-Za-z0-9._:-]{1,160}$/.test(value); }
    var eventKinds = {task_started:'start',task_complete:'complete',turn_aborted:'abort',
        item_completed:'execution',token_count:'execution'};
    function fresh() { return {offset:0,inode:null,pending:$.NSMutableData.data,
        phase:'unknown',turn:null,activity:null,latestStart:null,latestTerminal:null}; }
    function readLog(home, row, hudStart, time) {
        var alias = home.aliases[row.rollout_path];
        if (!alias) { alias = home.alias + '-T' + (++home.aliasCount); home.aliases[row.rollout_path] = alias; }
        var entry = {task:alias,readBytes:0,events:{},invalidTurnID:0,
            invalidTimestamp:0,malformedJSON:0,skippedBytes:0};
        var path = unwrap($.NSURL.fileURLWithPath(row.rollout_path).URLByResolvingSymlinksInPath.path);
        if (path.indexOf(home.path + '/sessions/') !== 0 || !/\.jsonl$/.test(path)) {
            entry.error = 'path_excluded_by_HUD'; return entry;
        }
        var cursor = home.cursors[row.rollout_path] || fresh(), handle = null;
        try {
            var attrs = fm.attributesOfItemAtPathError(path,null);
            if (!attrs) throw Error('unreadable');
            var size = Number(unwrap(attrs.objectForKey('NSFileSize')));
            var inode = Number(unwrap(attrs.objectForKey('NSFileSystemFileNumber')));
            var first = cursor.inode === null, baseline = !first && cursor.inode === inode && size >= cursor.offset;
            if (!baseline) cursor = fresh();
            cursor.inode = inode; entry.logBytes = size; entry.reset = !first && !baseline;
            var discard = false, skipped = size - cursor.offset > budget;
            if (skipped) {
                entry.skippedBytes = size - cursor.offset - budget;
                cursor.offset = size - budget; cursor.pending = $.NSMutableData.data;
                cursor.phase = 'unknown'; cursor.turn = null; cursor.activity = null; discard = true;
            }
            if (size > cursor.offset) {
                handle = $.NSFileHandle.fileHandleForReadingAtPath(path);
                if (!handle) throw Error('unreadable');
                handle.seekToFileOffset(cursor.offset);
                var bytes = handle.readDataOfLength(budget); handle.closeFile; handle = null;
                entry.readBytes = Number(bytes.length); cursor.offset += Number(bytes.length);
                cursor.pending.appendData(bytes);
                while (cursor.pending.length) {
                    var range = cursor.pending.rangeOfDataOptionsRange(newline,0,$.NSMakeRange(0,cursor.pending.length));
                    var end = Number(range.location);
                    if (end >= Number(cursor.pending.length)) break;
                    var line = cursor.pending.subdataWithRange($.NSMakeRange(0,end));
                    cursor.pending.setData(cursor.pending.subdataWithRange($.NSMakeRange(end+1,cursor.pending.length-end-1)));
                    if (discard) { discard = false; continue; }
                    var string = $.NSString.alloc.initWithDataEncoding(line,$.NSUTF8StringEncoding), root;
                    try { root = JSON.parse(string ? ObjC.unwrap(string) : ''); }
                    catch (_) { entry.malformedJSON++; continue; }
                    if (!root || root.type !== 'event_msg' || !root.payload) continue;
                    var payload = root.payload;
                    var kind = typeof payload.type === 'string' && Object.prototype.hasOwnProperty.call(eventKinds,payload.type)
                        ? eventKinds[payload.type] : null;
                    var event = kind ? payload.type : 'other_event';
                    entry.events[event] = (entry.events[event] || 0) + 1;
                    if (!kind) continue;
                    var isoTime = typeof root.timestamp === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(root.timestamp);
                    var stamp = isoTime ? Date.parse(root.timestamp)/1000 : NaN;
                    if (!isFinite(stamp)) { entry.invalidTimestamp++; continue; }
                    if (!validID(payload.turn_id)) { entry.invalidTurnID++; continue; }
                    if (kind === 'start') cursor.latestStart = stamp;
                    if (kind === 'complete' || kind === 'abort') cursor.latestTerminal = stamp;
                    if (kind === 'execution' && payload.turn_id !== cursor.turn) continue;
                    if ((kind === 'complete' || kind === 'abort') && cursor.turn !== null && payload.turn_id !== cursor.turn) continue;
                    if (cursor.activity !== null && stamp < cursor.activity) continue;
                    var live = (baseline && !skipped) || (first && stamp >= started);
                    if (kind === 'start') {
                        cursor.phase = live ? 'running' : 'unknown';
                        if (stamp >= started) home.liveStarts++;
                    } else if (kind === 'execution') {
                        if (!live || cursor.phase !== 'running' || cursor.activity === null || stamp - cursor.activity >= 1800) continue;
                    } else cursor.phase = kind === 'complete' ? 'completed' : 'interrupted';
                    cursor.activity = stamp; cursor.turn = payload.turn_id;
                }
                if (cursor.pending.length > budget) { cursor.pending = $.NSMutableData.data; cursor.phase = 'unknown'; }
            }
            home.cursors[row.rollout_path] = cursor;
            var age = cursor.activity === null ? null : time - cursor.activity;
            entry.modelPhase = cursor.phase;
            entry.modelRunning = cursor.phase === 'running' && age >= -5 && age < 1800;
            if (cursor.phase === 'running' && !entry.modelRunning) entry.modelPhase = 'unknown_stale_or_future';
            entry.lastEvidenceAgeSeconds = age === null ? null : Math.round(age);
            entry.latestStartAgeSeconds = cursor.latestStart === null ? null : Math.round(time - cursor.latestStart);
            entry.latestStartBeforeHUDLaunch = cursor.latestStart === null || hudStart === null ? null : cursor.latestStart < hudStart;
            entry.latestTerminalAgeSeconds = cursor.latestTerminal === null ? null : Math.round(time - cursor.latestTerminal);
            entry.pendingBytes = Number(cursor.pending.length);
        } catch (_) {
            if (handle) try { handle.closeFile; } catch (_) {}
            home.readFailures++; entry.error = 'log_read_failed';
        }
        return entry;
    }
    function discover(home, time) {
        home.nextDiscovery = time + 10;
        var db = home.path + '/state_5.sqlite';
        if (!fm.fileExistsAtPath(db)) { home.discovery = 'database_missing'; home.selected = []; return; }
        var schema = sql(db,'PRAGMA table_info(threads);');
        if (schema.error) { home.discovery = schema.error; return; }
        var fields = schema.rows.map(function(row) { return row.name; });
        var required = ['rollout_path','source','archived','updated_at'];
        home.schema = {required:required.map(function(field) { return {field:field,present:fields.indexOf(field)>=0}; }),
            cliVersionPresent:fields.indexOf('cli_version')>=0};
        if (required.some(function(field) { return fields.indexOf(field)<0; })) {
            home.discovery = 'schema_incompatible'; home.selected = []; return;
        }
        var groups = sql(db,"SELECT CASE WHEN source IN ('cli','exec','vscode') THEN source WHEN source LIKE '{%subagent%' THEN 'subagent' ELSE 'other' END AS category,COUNT(*) AS count FROM threads WHERE archived=0 GROUP BY category;");
        home.sourceCounts = groups.rows || []; home.sourceCountsError = groups.error || null;
        if (home.schema.cliVersionPresent) {
            var versions = sql(db,"SELECT DISTINCT cli_version FROM threads WHERE archived=0 AND source IN ('cli','exec','vscode') ORDER BY updated_at DESC LIMIT 32;");
            home.cliVersions = (versions.rows || []).map(function(row) { return version(row.cli_version); }).filter(function(value) { return value !== null; });
        }
        // Keep candidate discovery identical to TaskStatusMonitor v0.1.40.
        var query = "SELECT DISTINCT rollout_path FROM threads WHERE archived=0 AND source IN ('cli','exec','vscode') ORDER BY updated_at DESC LIMIT 32;";
        var found = sql(db,query);
        if (found.error) { home.discovery = found.error; return; }
        home.selected = found.rows.filter(function(row) { return typeof row.rollout_path === 'string'; });
        var active = {};
        home.selected.forEach(function(row) { active[row.rollout_path] = true; });
        // Compare recent unfiltered metadata to the exact production selection.
        // Export only fixed source categories and anonymous path aliases.
        var recent = sql(db,"SELECT rollout_path,updated_at,CASE WHEN source IN ('cli','exec','vscode') THEN source WHEN source LIKE '{%subagent%' THEN 'subagent' ELSE 'other' END AS category FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 32;");
        home.recentIndexError = recent.error || null;
        home.recentIndex = (recent.rows || []).map(function(row) {
            var alias = home.aliases[row.rollout_path];
            if (!alias) { alias = home.alias + '-T' + (++home.aliasCount); home.aliases[row.rollout_path] = alias; }
            var path = typeof row.rollout_path === 'string' ? unwrap($.NSURL.fileURLWithPath(row.rollout_path).URLByResolvingSymlinksInPath.path) : '';
            var modified = Number(row.updated_at);
            return {task:alias,category:row.category,selectedByHUD:active[row.rollout_path] === true,
                pathAllowedByHUD:path.indexOf(home.path + '/sessions/') === 0 && /\.jsonl$/.test(path),
                indexAgeSeconds:row.updated_at !== null && isFinite(modified) ? Math.round(time-modified) : null};
        });
        Object.keys(home.cursors).forEach(function(path) { if (!active[path]) delete home.cursors[path]; });
        home.discovery = 'ok';
    }
    function signature(running, role) {
        return JSON.stringify(running.filter(function(app) { return app.role === role; }).map(function(app) {
            return [app.pid,app.launchedAt];
        }).sort(function(a,b) { return a[0]-b[0]; }));
    }
    var sample = 0, previousProcesses = null, processChangeCounts = {hud:0,codex:0};
    try {
        while (true) {
            var time = now(), running = apps();
            var huds = running.filter(function(app) { return app.role === 'HUD'; });
            var hudStart = huds.length === 1 ? huds[0].launchedAt : null;
            var processes = {hud:signature(running,'HUD'),codex:signature(running,'Codex')};
            var changes = {hud:previousProcesses === null ? null : processes.hud !== previousProcesses.hud,
                codex:previousProcesses === null ? null : processes.codex !== previousProcesses.codex};
            if (changes.hud) processChangeCounts.hud++;
            if (changes.codex) processChangeCounts.codex++;
            previousProcesses = processes;
            var output = {type:'sample',sample:sample++,elapsedSeconds:Math.round(time-started),
                apps:running,processChanges:changes,savedPreferences:preferences(hudID),homes:[]};
            homes.forEach(function(home) {
                if (time >= home.nextDiscovery) discover(home,time);
                var entries = home.selected.map(function(row) { return readLog(home,row,hudStart,time); });
                var count = entries.filter(function(entry) { return entry.modelRunning; }).length;
                home.maxRunning = Math.max(home.maxRunning,count);
                output.homes.push({alias:home.alias,discovery:home.discovery,schema:home.schema || null,
                    sourceCounts:home.sourceCounts || [],sourceCountsError:home.sourceCountsError || null,
                    recentLocalCLIVersions:home.cliVersions || [],
                    recentIndex:home.recentIndex || [],recentIndexError:home.recentIndexError || null,
                    selectedCandidates:home.selected.length,independentModelRunning:count,tasks:entries});
            });
            emit(output);
            if (now()-started >= seconds) break;
            delay(Math.min(2,seconds-(now()-started)));
        }
        emit({type:'footer',completed:true,stage:stage,processChangeCounts:processChangeCounts,samples:sample,elapsedSeconds:Math.round(now()-started),
            homes:homes.map(function(home) { return {alias:home.alias,maxIndependentModelRunning:home.maxRunning,
                startsSinceProbeStart:home.liveStarts,logReadFailures:home.readFailures}; }),
            limitations:['Does not read HUD memory or assert that the Touch Bar rendered.',
                'Hooks mode is recorded but not simulated; no hooks are installed or invoked.',
                'Probe starts after HUD: initial historical tasks can remain unknown in this independent model.']});
    } catch (_) { emit({type:'footer',completed:false,error:'probe_failed',samples:sample}); throw Error('probe_failed'); }
    finally { report.closeFile; }
    return '监控完成。请把桌面上的 TouchBar-task-diagnostics 报告发回，并注明新任务大约在第几秒开始、屏幕上是否出现任务数字。';
}
TASK_DIAG_JXA
then
    echo "已保存：$task_diag_report"
else
    echo "诊断未完整完成；已采集的结果保留在：$task_diag_report"
    exit 1
fi
