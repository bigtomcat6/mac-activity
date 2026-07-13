// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioNativeValidation",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "MacActivity", path: "../..")],
    targets: [
        .target(
            name: "AudioNativePreflightKit",
            dependencies: [.product(name: "MacActivityCore", package: "MacActivity")]
        ),
        .executableTarget(
            name: "AudioNativePreflight",
            dependencies: ["AudioNativePreflightKit"]
        ),
        .testTarget(
            name: "AudioNativeValidationTests",
            dependencies: [
                "AudioNativePreflightKit",
                .product(name: "MacActivityCore", package: "MacActivity"),
            ]
        ),
    ]
)
