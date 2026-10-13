// swift-tools-version: 5.8

import PackageDescription
import Foundation

// Test-only builds retain the real core targets and every test. Production builds
// keep the default graph, including both executables.
let coreTestsOnly = ProcessInfo.processInfo.environment["HUD_CORE_TESTS_ONLY"] == "1"

var targets: [Target] = [
    .target(name: "HookCore", path: "HookCore"),
    .target(name: "ResetNewsCore", path: "ResetNewsCore"),
    .testTarget(name: "HookCoreTests", dependencies: ["HookCore"], path: "Tests/HookCoreTests"),
    .testTarget(name: "ResetNewsCoreTests", dependencies: ["ResetNewsCore"], path: "Tests/ResetNewsCoreTests")
]
if !coreTestsOnly {
    targets += [
        .executableTarget(name: "GPTTouchBarHUD", dependencies: ["HookCore", "ResetNewsCore"], path: "Sources"),
        .executableTarget(name: "HookEmitter", dependencies: ["HookCore"], path: "HookHelper")
    ]
}

let package = Package(
    name: "GPTTouchBarHUD",
    platforms: [
        .macOS(.v11)
    ],
    products: coreTestsOnly ? [] : [
        .executable(name: "GPTTouchBarHUD", targets: ["GPTTouchBarHUD"]),
        .executable(name: "HookEmitter", targets: ["HookEmitter"])
    ],
    targets: targets
)
