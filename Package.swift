// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacActivity",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "MacActivityBatteryControl", targets: ["MacActivityBatteryControl"]),
        .library(
            name: "MacActivityCore",
            targets: ["MacActivityCore"]
        ),
        .executable(
            name: "MacActivityApp",
            targets: ["MacActivityApp"]
        ),
        .executable(
            name: "DebugActiveProcessMemory",
            targets: ["DebugActiveProcessMemory"]
        ),
        .executable(
            name: "DebugDiskCleanup",
            targets: ["DebugDiskCleanup"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        .target(name: "MacActivityBatteryControl", path: "Sources/MacActivityBatteryControl"),
        .testTarget(
            name: "MacActivityBatteryControlTests",
            dependencies: ["MacActivityBatteryControl"],
            path: "Tests/MacActivityBatteryControlTests"
        ),
        .target(
            name: "MacActivityCore",
            dependencies: ["MacActivityBatteryControl"],
            path: "Sources/MacActivityCore"
        ),
        .executableTarget(
            name: "MacActivityApp",
            dependencies: [
                "MacActivityCore",
                "MacActivityBatteryControl",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MacActivityApp",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "DebugActiveProcessMemory",
            dependencies: ["MacActivityCore"],
            path: "Tools/DebugActiveProcessMemory"
        ),
        .executableTarget(
            name: "DebugDiskCleanup",
            dependencies: ["MacActivityCore"],
            path: "Tools/DebugDiskCleanup"
        ),
        .testTarget(
            name: "MacActivityCoreTests",
            dependencies: ["MacActivityCore", "MacActivityBatteryControl"],
            path: "Tests/MacActivityCoreTests"
        ),
        .testTarget(
            name: "MacActivityAppTests",
            dependencies: ["MacActivityApp", "MacActivityBatteryControl"],
            path: "Tests/MacActivityAppTests"
        ),
    ]
)
