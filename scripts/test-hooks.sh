#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# CLT 6.4 ships TestingMacros in a nested plugin directory not searched by swiftbuild.
# Supply the existing bundled plugin when present; do not install a package or change the toolchain.
swift_bin="$(xcrun --find swiftc)"
testing_plugin="$(dirname "$swift_bin")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
flags=()
if [[ -f "$testing_plugin" ]]; then
    flags=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test "${flags[@]}" "$@"
