// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WisprClaw",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "WisprClaw",
            path: "Sources/WisprClaw"
        )
    ]
)
