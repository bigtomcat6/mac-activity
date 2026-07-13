import Foundation
import XCTest

final class AudioNativePreflightSourceSafetyTests: XCTestCase {
    func testExecutableSourcesContainNoLiveOrMutableAudioSeams() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            packageRoot.appendingPathComponent("Sources/AudioNativePreflight"),
            packageRoot.appendingPathComponent("Sources/AudioNativePreflightKit"),
        ]
        let sourceURLs = sourceRoots.flatMap(swiftSourceURLs)

        XCTAssertFalse(sourceURLs.isEmpty, "AudioNativePreflight sources must exist")

        let forbiddenReferences = [
            "MACACTIVITY_AUDIO_NATIVE_VALIDATION",
            "MACACTIVITY_RUN_AUDIO_NATIVE_TESTS",
            "writeVolume(",
            "writeMute(",
            "writeScalar(",
            "writeObject(",
            "AudioRoutePlanner",
            "ProcessTapVolumeEngine",
            "AudioSystemMonitor",
            "AudioControlCoordinator",
            "CoreAudioTapHardware",
            "AudioProcessOwnershipLease",
            "PreferencesStore",
            "AudioHardwareCreateProcessTap",
            "AudioHardwareDestroyProcessTap",
            "AudioHardwareCreateAggregateDevice",
            "AudioHardwareDestroyAggregateDevice",
            "AudioDeviceCreateIOProcID",
            "AudioDeviceDestroyIOProcID",
            "AudioDeviceStart",
            "AudioDeviceStop",
            "AudioObjectSetPropertyData",
            "try?",
        ]

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for forbiddenReference in forbiddenReferences {
                XCTAssertFalse(
                    source.contains(forbiddenReference),
                    "\(sourceURL.lastPathComponent) references forbidden seam \(forbiddenReference)"
                )
            }
        }
    }

    func testSourceScannerIncludesNestedSwiftFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioNativePreflightSourceScan-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Nested/Deeper")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let swiftFile = nested.appendingPathComponent("Nested.swift")
        try Data("// fixture\n".utf8).write(to: swiftFile)

        let discovered = swiftSourceURLs(root)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertTrue(discovered[0].path.hasSuffix("/Nested/Deeper/Nested.swift"))
    }

    private func swiftSourceURLs(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}
