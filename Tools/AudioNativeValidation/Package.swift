// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioNativeValidation",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "MacActivity", path: "../..")],
    targets: [
        .testTarget(
            name: "AudioNativeValidationTests",
            dependencies: [.product(name: "MacActivityCore", package: "MacActivity")]
        ),
    ]
)
