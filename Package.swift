// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacActivity",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MacActivityCore",
            targets: ["MacActivityCore"]
        ),
        .executable(
            name: "MacActivityApp",
            targets: ["MacActivityApp"]
        ),
        .executable(
            name: "DebugMemoryRelease",
            targets: ["DebugMemoryRelease"]
        ),
        .executable(
            name: "DebugActiveProcessMemory",
            targets: ["DebugActiveProcessMemory"]
        ),
        .executable(
            name: "DebugMemoryReleaseUI",
            targets: ["DebugMemoryReleaseUI"]
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
        .target(
            name: "MacActivityCore",
            path: "Sources/MacActivityCore"
        ),
        .executableTarget(
            name: "MacActivityApp",
            dependencies: [
                "MacActivityCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MacActivityApp",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "DebugMemoryRelease",
            dependencies: ["MacActivityCore"],
            path: "Tools/DebugMemoryRelease"
        ),
        .executableTarget(
            name: "DebugActiveProcessMemory",
            dependencies: ["MacActivityCore"],
            path: "Tools/DebugActiveProcessMemory"
        ),
        .executableTarget(
            name: "DebugMemoryReleaseUI",
            path: "Tools/DebugMemoryReleaseUI"
        ),
        .executableTarget(
            name: "DebugDiskCleanup",
            dependencies: ["MacActivityCore"],
            path: "Tools/DebugDiskCleanup"
        ),
        .testTarget(
            name: "MacActivityCoreTests",
            dependencies: ["MacActivityCore"],
            path: "Tests/MacActivityCoreTests"
        ),
        .testTarget(
            name: "MacActivityAppTests",
            dependencies: ["MacActivityApp"],
            path: "Tests/MacActivityAppTests"
        ),
    ]
)
