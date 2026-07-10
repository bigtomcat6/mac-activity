import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioProcessServiceTests: XCTestCase {
    func testProcessIdentityUsesAudioObjectIDEvenWhenPIDIsReused() {
        let first = AudioProcessEntry(
            processObjectID: 11,
            processIdentifier: 101,
            name: "Old Player",
            bundleIdentifier: "com.example.Player",
            bundleURL: nil,
            outputDeviceIDs: [50]
        )
        let replacement = AudioProcessEntry(
            processObjectID: 22,
            processIdentifier: 101,
            name: "New Player",
            bundleIdentifier: "com.example.Player",
            bundleURL: nil,
            outputDeviceIDs: [50]
        )

        XCTAssertNotEqual(first.id, replacement.id)
        XCTAssertEqual(first.processIdentifier, replacement.processIdentifier)
    }

    @MainActor
    func testDefaultLiveReaderReturnsEmptyWithoutCallingHALWhenRuntimeUnavailable() {
        var didReadSnapshots = false

        let snapshots = AudioProcessService.readProcessSnapshotsIfAvailable(
            isRuntimeProcessDiscoveryAvailable: false,
            reader: {
                didReadSnapshots = true
                return [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: "com.apple.Music",
                        isRunningOutput: true
                    ),
                ]
            }
        )

        XCTAssertEqual(snapshots, [])
        XCTAssertFalse(didReadSnapshots)
    }

    @MainActor
    func testAudibleOutputProcessesReturnsEmptyWithoutTouchingSnapshotsWhenAvailabilityUnsupported() {
        var didReadSnapshots = false
        let service = AudioProcessService(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 1,
                    patchVersion: 0
                )
            ),
            processSnapshotReader: {
                didReadSnapshots = true
                return [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: "com.apple.Music",
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: {
                XCTFail("App snapshots should not be read when availability is unsupported")
                return []
            }
        )

        XCTAssertEqual(service.audibleOutputProcesses(), [])
        XCTAssertFalse(didReadSnapshots)
    }

    @MainActor
    func testAudibleOutputProcessesUsesInjectedSnapshotsWhenAvailabilitySupported() {
        let service = AudioProcessService(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )
            ),
            processSnapshotReader: {
                [
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
                ]
            },
            appSnapshotReader: {
                [
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
            }
        )

        let entries = service.audibleOutputProcesses()

        XCTAssertEqual(entries.map(\.name), ["Music"])
        XCTAssertEqual(entries[0].processObjectID, 11)
        XCTAssertEqual(entries[0].processIdentifier, 101)
    }

    func testEntriesKeepOnlyRunningOutputProcesses() {
        let entries = AudioProcessService.makeEntries(
            processObjects: [
                AudioProcessSnapshot(
                    processObjectID: 11,
                    processIdentifier: 101,
                    bundleIdentifier: "com.apple.Music",
                    isRunningOutput: true,
                    outputDeviceIDs: [50, 51]
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
        XCTAssertEqual(entries[0].outputDeviceIDs, [50, 51])
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

    @MainActor
    func testLiveSnapshotsReadEveryProcessPropertyThroughSharedHALClient() throws {
        guard #available(macOS 14.2, *) else { return }

        let backend = FakeAudioHALBackend()
        backend.setArray(
            [AudioObjectID(11)],
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: .init(selector: kAudioHardwarePropertyProcessObjectList)
        )
        backend.setScalar(
            pid_t(101),
            objectID: 11,
            address: .init(selector: kAudioProcessPropertyPID)
        )
        backend.setString(
            "com.apple.Music",
            objectID: 11,
            address: .init(selector: kAudioProcessPropertyBundleID)
        )
        backend.setScalar(
            UInt32(1),
            objectID: 11,
            address: .init(selector: kAudioProcessPropertyIsRunningOutput)
        )
        backend.setArray(
            [AudioDeviceID(50), 51],
            objectID: 11,
            address: .init(
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            )
        )

        let snapshots = AudioProcessService.readProcessSnapshotsIfAvailable(
            client: AudioHALClient(backend: backend)
        )

        XCTAssertEqual(
            snapshots,
            [
                AudioProcessSnapshot(
                    processObjectID: 11,
                    processIdentifier: 101,
                    bundleIdentifier: "com.apple.Music",
                    isRunningOutput: true,
                    outputDeviceIDs: [50, 51]
                ),
            ]
        )
        XCTAssertTrue(backend.readSelectors.contains(kAudioProcessPropertyDevices))
    }
}
