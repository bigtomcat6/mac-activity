// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacActivity",
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
    ],
    targets: [
        .target(
            name: "MacActivityCore",
            path: "Sources/MacActivityCore"
        ),
        .executableTarget(
            name: "MacActivityApp",
            dependencies: ["MacActivityCore"],
            path: "Sources/MacActivityApp"
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
