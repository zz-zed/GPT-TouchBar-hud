// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "GPTTouchBarHUD",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "GPTTouchBarHUD", targets: ["GPTTouchBarHUD"]),
        .executable(name: "HookEmitter", targets: ["HookEmitter"])
    ],
    targets: [
        .executableTarget(
            name: "GPTTouchBarHUD",
            dependencies: ["HookCore"],
            path: "Sources"
        ),
        .target(name: "HookCore", path: "HookCore"),
        .executableTarget(name: "HookEmitter", dependencies: ["HookCore"], path: "HookHelper"),
        .testTarget(name: "HookCoreTests", dependencies: ["HookCore"], path: "Tests/HookCoreTests")
    ]
)
