// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "GPTTouchBarHUD",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "GPTTouchBarHUD", targets: ["GPTTouchBarHUD"])
    ],
    targets: [
        .executableTarget(
            name: "GPTTouchBarHUD",
            path: "Sources"
        )
    ]
)
