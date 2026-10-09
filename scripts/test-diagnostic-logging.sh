#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/diagnostic-tests
source scripts/hook-core-build.sh
source scripts/swift-module-cache.sh
DIAGNOSTIC_ARCH="$(uname -m)"
DIAGNOSTIC_TARGET="${DIAGNOSTIC_ARCH}-apple-macosx11.0"
DIAGNOSTIC_CACHE="$(swift_module_cache_path "$DIAGNOSTIC_TARGET")"
flags=(-swift-version 5 -target "$DIAGNOSTIC_TARGET" -module-cache-path "$DIAGNOSTIC_CACHE")
core=(Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticProcessStore.swift Sources/DiagnosticStore.swift Sources/DiagnosticRecorder.swift)
swiftc "${flags[@]}" Sources/DiagnosticEnvironment.swift Tests/DiagnosticEnvironmentTests.swift -o .build/diagnostic-tests/environment
.build/diagnostic-tests/environment
swiftc "${flags[@]}" "${core[@]}" Tests/DiagnosticRecorderTests.swift -o .build/diagnostic-tests/recorder
.build/diagnostic-tests/recorder
swiftc "${flags[@]}" "${HOOK_CORE_SWIFT_FLAGS[@]}" "${core[@]}" \
    Sources/DiagnosticEnvironment.swift Sources/DiagnosticTaskTraceCoverage.swift Sources/DiagnosticExport.swift Sources/ConnectionDiagnostics.swift Sources/ConnectionDiagnosticsWindowController.swift \
    Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
    Tests/DiagnosticExportTests.swift -o .build/diagnostic-tests/export
.build/diagnostic-tests/export
swiftc "${flags[@]}" "${HOOK_CORE_SWIFT_FLAGS[@]}" Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift \
    Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/TaskStatusMonitor.swift Sources/DiagnosticHookTaskTrace.swift Sources/TaskMonitoringCoordinator.swift \
    Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
    Tests/DiagnosticIntegrationTests.swift -o .build/diagnostic-tests/integration
.build/diagnostic-tests/integration
bash scripts/test-diagnostic-task-trace.sh
python3 - <<'PY'
from pathlib import Path
import re
violations=[]
for path in Path('Sources').glob('*.swift'):
    for line_no,line in enumerate(path.read_text().splitlines(),1):
        if re.search(r'\b(NSLog|print|debugPrint|dump|fputs)\s*\(',line):
            violations.append(f'{path}:{line_no}: unreviewed direct logging')
assert not violations, '\n'.join(violations)
print('PASS: application output channels use typed diagnostic boundary')
PY
