import XCTest
@testable import MacActivityCore

final class AudioProcessServiceTests: XCTestCase {
    func testEntriesKeepOnlyRunningOutputProcesses() {
        let entries = AudioProcessService.makeEntries(
            processObjects: [
                AudioProcessSnapshot(
                    processObjectID: 11,
                    processIdentifier: 101,
                    bundleIdentifier: "com.apple.Music",
                    isRunningOutput: true
                ),
                AudioProcessSnapshot(
                    processObjectID: 12,
                    processIdentifier: 102,
                    bundleIdentifier: "com.apple.Notes",
                    isRunningOutput: false
                ),
            ],
            apps: [
                AudioProcessAppSnapshot(
                    processIdentifier: 101,
                    name: "Music",
                    bundleIdentifier: "com.apple.Music",
                    bundleURL: URL(fileURLWithPath: "/System/Applications/Music.app")
                ),
                AudioProcessAppSnapshot(
                    processIdentifier: 102,
                    name: "Notes",
                    bundleIdentifier: "com.apple.Notes",
                    bundleURL: URL(fileURLWithPath: "/System/Applications/Notes.app")
                ),
            ]
        )

        XCTAssertEqual(entries.map(\.name), ["Music"])
        XCTAssertEqual(entries[0].processObjectID, 11)
        XCTAssertEqual(entries[0].processIdentifier, 101)
    }

    func testEntriesUseBundleIDWhenWorkspaceAppIsMissing() {
        let entries = AudioProcessService.makeEntries(
            processObjects: [
                AudioProcessSnapshot(
                    processObjectID: 11,
                    processIdentifier: 101,
                    bundleIdentifier: "com.example.Player",
                    isRunningOutput: true
                ),
            ],
            apps: []
        )

        XCTAssertEqual(entries[0].name, "com.example.Player")
        XCTAssertEqual(entries[0].bundleIdentifier, "com.example.Player")
    }
}
