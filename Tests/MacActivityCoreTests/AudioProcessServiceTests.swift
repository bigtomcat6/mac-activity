import CoreAudio
import Foundation
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
    func testInjectedLiveReaderRunsWhenRuntimeIsAvailable() {
        let expected = AudioProcessSnapshot(
            processObjectID: 11,
            processIdentifier: 101,
            bundleIdentifier: "com.apple.Music",
            isRunningOutput: true
        )

        XCTAssertEqual(
            AudioProcessService.readProcessSnapshotsIfAvailable(
                isRuntimeProcessDiscoveryAvailable: true,
                reader: { [expected] in [expected] }
            ),
            [expected]
        )
    }

    @MainActor
    func testDefaultRuntimeAvailabilityOnlyInvokesInjectedReaderWhenSupported() {
        var didReadSnapshots = false

        let snapshots = AudioProcessService.readProcessSnapshotsIfAvailable(
            reader: {
                didReadSnapshots = true
                return []
            }
        )

        if #available(macOS 14.2, *) {
            XCTAssertTrue(didReadSnapshots)
        } else {
            XCTAssertFalse(didReadSnapshots)
        }
        XCTAssertEqual(snapshots, [])
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
    func testMacOS142ProcessDiscoveryUsesInjectedSnapshots() {
        var didReadSnapshots = false
        let service = AudioProcessService(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )
            ),
            processSnapshotReader: {
                didReadSnapshots = true
                return []
            },
            appSnapshotReader: {
                return []
            }
        )

        XCTAssertEqual(service.audibleOutputProcesses(), [])
        XCTAssertTrue(didReadSnapshots)
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

    @MainActor
    func testAudibleOutputProcessesCachesEveryNonOwnDiscoveredProcessWithoutAnotherRead() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var snapshotReadCount = 0
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                snapshotReadCount += 1
                return [
                    AudioProcessSnapshot(
                        processObjectID: 10,
                        processIdentifier: ownPID,
                        bundleIdentifier: "com.example.MacActivity",
                        isRunningOutput: false
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: ownPID + 1,
                        bundleIdentifier: "com.example.Player",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 12,
                        processIdentifier: ownPID + 2,
                        bundleIdentifier: "com.example.Dormant",
                        isRunningOutput: false
                    ),
                ]
            },
            appSnapshotReader: { [] }
        )

        XCTAssertEqual(service.audibleOutputProcesses().map(\.processObjectID), [11])
        XCTAssertEqual(service.discoveredProcessObjectIDs, Set<AudioObjectID>([11, 12]))
        XCTAssertEqual(snapshotReadCount, 1)
    }

    @MainActor
    func testAudibleOutputProcessesExcludesCurrentPIDWithoutWorkspaceMetadata() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherPID = ownPID + 1
        let nonRunningPID = ownPID + 2
        let service = AudioProcessService(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )
            ),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: ownPID,
                        bundleIdentifier: nil,
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 12,
                        processIdentifier: otherPID,
                        bundleIdentifier: "com.example.Other",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 13,
                        processIdentifier: nonRunningPID,
                        bundleIdentifier: "com.example.Inactive",
                        isRunningOutput: false
                    ),
                ]
            },
            appSnapshotReader: {
                [
                    AudioProcessAppSnapshot(
                        processIdentifier: otherPID,
                        name: "Mac Activity",
                        bundleIdentifier: "com.example.Other",
                        bundleURL: nil
                    ),
                ]
            }
        )

        let entries = service.audibleOutputProcesses()

        XCTAssertEqual(entries.map(\.processObjectID), [12])
        XCTAssertEqual(entries.map(\.processIdentifier), [otherPID])
        XCTAssertEqual(entries.map(\.name), ["Mac Activity"])
    }

    @MainActor
    func testAudibleOutputProcessesExcludesCurrentPIDWithWorkspaceMetadataAndSameNamedProcess() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherPID = ownPID + 1
        let service = AudioProcessService(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )
            ),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: ownPID,
                        bundleIdentifier: "com.example.MacActivity",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 12,
                        processIdentifier: otherPID,
                        bundleIdentifier: "com.example.Other",
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: {
                [
                    AudioProcessAppSnapshot(
                        processIdentifier: ownPID,
                        name: "Mac Activity",
                        bundleIdentifier: "com.example.MacActivity",
                        bundleURL: nil
                    ),
                    AudioProcessAppSnapshot(
                        processIdentifier: otherPID,
                        name: "Mac Activity",
                        bundleIdentifier: "com.example.Other",
                        bundleURL: nil
                    ),
                ]
            }
        )

        let entries = service.audibleOutputProcesses()

        XCTAssertEqual(entries.map(\.processObjectID), [12])
        XCTAssertEqual(entries.map(\.processIdentifier), [otherPID])
        XCTAssertEqual(entries.map(\.name), ["Mac Activity"])
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

    @MainActor
    func testLiveSnapshotListReadFailureReturnsEmpty() {
        guard #available(macOS 14.2, *) else { return }

        let backend = FakeAudioHALBackend()
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: .init(selector: kAudioHardwarePropertyProcessObjectList),
            announcedByteCount: UInt32(MemoryLayout<AudioObjectID>.stride)
        )

        XCTAssertEqual(
            AudioProcessService.readProcessSnapshotsIfAvailable(
                client: AudioHALClient(backend: backend)
            ),
            []
        )
    }

    @MainActor
    func testLiveSnapshotsSkipMissingPIDAndDefaultMissingOptionalProperties() {
        guard #available(macOS 14.2, *) else { return }

        let backend = FakeAudioHALBackend()
        backend.setArray(
            [AudioObjectID(11), 12],
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: .init(selector: kAudioHardwarePropertyProcessObjectList)
        )
        backend.setScalar(
            pid_t(101),
            objectID: 11,
            address: .init(selector: kAudioProcessPropertyPID)
        )
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: 12,
            address: .init(selector: kAudioProcessPropertyPID),
            announcedByteCount: UInt32(MemoryLayout<pid_t>.stride)
        )

        XCTAssertEqual(
            AudioProcessService.readProcessSnapshotsIfAvailable(
                client: AudioHALClient(backend: backend)
            ),
            [
                AudioProcessSnapshot(
                    processObjectID: 11,
                    processIdentifier: 101,
                    bundleIdentifier: nil,
                    isRunningOutput: false,
                    outputDeviceIDs: []
                ),
            ]
        )
    }

    @MainActor
    func testAudibleOutputProcessesMapAppAndSnapshotFallbackMetadata() {
        let appURL = URL(fileURLWithPath: "/Applications/Studio.app")
        let service = AudioProcessService(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(
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
                        bundleIdentifier: "com.example.Player",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 12,
                        processIdentifier: 102,
                        bundleIdentifier: nil,
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 13,
                        processIdentifier: 103,
                        bundleIdentifier: "com.example.Studio",
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: {
                [
                    AudioProcessAppSnapshot(
                        processIdentifier: 103,
                        name: "Studio",
                        bundleIdentifier: nil,
                        bundleURL: appURL
                    ),
                ]
            }
        )

        let entriesByObjectID = Dictionary(
            uniqueKeysWithValues: service.audibleOutputProcesses().map {
                ($0.processObjectID, $0)
            }
        )

        XCTAssertEqual(entriesByObjectID[11]?.name, "com.example.Player")
        XCTAssertEqual(entriesByObjectID[11]?.bundleIdentifier, "com.example.Player")
        XCTAssertNil(entriesByObjectID[11]?.bundleURL)
        XCTAssertEqual(entriesByObjectID[12]?.name, "Process 102")
        XCTAssertNil(entriesByObjectID[12]?.bundleIdentifier)
        XCTAssertEqual(entriesByObjectID[13]?.name, "Studio")
        XCTAssertEqual(entriesByObjectID[13]?.bundleIdentifier, "com.example.Studio")
        XCTAssertEqual(entriesByObjectID[13]?.bundleURL, appURL)
    }

    @MainActor
    func testAudibleOutputProcessesResolvesMissingWorkspaceMetadataFromBundleIdentifier() throws {
        let bundle = try makeApplicationBundle(
            named: "Resolver Fixture",
            info: [
                "CFBundleDisplayName": "Localized Player",
                "CFBundleName": "Fallback Player",
            ]
        )
        let bundleIdentifier = "com.example.resolved-player"
        var resolvedIdentifiers: [String] = []
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: bundleIdentifier,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: { [] },
            applicationURLReader: { identifier in
                resolvedIdentifiers.append(identifier)
                return identifier == bundleIdentifier ? bundle.bundleURL : nil
            }
        )

        let entry = try XCTUnwrap(service.audibleOutputProcesses().first)

        XCTAssertEqual(resolvedIdentifiers, [bundleIdentifier])
        XCTAssertEqual(entry.processObjectID, 11)
        XCTAssertEqual(entry.processIdentifier, 101)
        XCTAssertEqual(entry.name, "Localized Player")
        XCTAssertEqual(entry.bundleIdentifier, bundleIdentifier)
        XCTAssertEqual(entry.bundleURL, bundle.bundleURL)
    }

    @MainActor
    func testAudibleOutputProcessesReadsKnownWorkspaceBundleBeforeApplicationLookup() throws {
        let knownBundle = try makeApplicationBundle(
            named: "Known Bundle File",
            info: ["CFBundleDisplayName": "Known Bundle Display"]
        )
        let differentBundle = try makeApplicationBundle(
            named: "Different Bundle File",
            info: ["CFBundleDisplayName": "Different Bundle Display"]
        )
        let bundleIdentifier = "com.example.known-bundle"

        for lookupURL in [nil, differentBundle.bundleURL] as [URL?] {
            var lookupCount = 0
            var executableLookupCount = 0
            let service = AudioProcessService(
                availability: .init(operatingSystemVersion: .init(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )),
                processSnapshotReader: {
                    [
                        AudioProcessSnapshot(
                            processObjectID: 11,
                            processIdentifier: 101,
                            bundleIdentifier: bundleIdentifier,
                            isRunningOutput: true
                        ),
                    ]
                },
                appSnapshotReader: {
                    [
                        AudioProcessAppSnapshot(
                            processIdentifier: 101,
                            name: "",
                            bundleIdentifier: bundleIdentifier,
                            bundleURL: knownBundle.bundleURL
                        ),
                    ]
                },
                applicationURLReader: { _ in
                    lookupCount += 1
                    return lookupURL
                },
                processExecutableURLReader: { _ in
                    executableLookupCount += 1
                    return differentBundle.bundleURL
                }
            )

            let entry = try XCTUnwrap(service.audibleOutputProcesses().first)

            XCTAssertEqual(entry.name, "Known Bundle Display")
            XCTAssertEqual(entry.bundleURL, knownBundle.bundleURL)
            XCTAssertEqual(lookupCount, 0)
            XCTAssertEqual(executableLookupCount, 0)
        }
    }

    @MainActor
    func testAudibleOutputProcessesUsesBundleMetadataWhenWorkspaceNameIsWhitespace() throws {
        let bundle = try makeApplicationBundle(
            named: "Workspace Bundle File",
            info: ["CFBundleDisplayName": "Workspace Bundle Display"]
        )
        let bundleIdentifier = "com.example.workspace-whitespace"
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: bundleIdentifier,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: {
                [
                    AudioProcessAppSnapshot(
                        processIdentifier: 101,
                        name: " \n\t",
                        bundleIdentifier: bundleIdentifier,
                        bundleURL: bundle.bundleURL
                    ),
                ]
            },
            applicationURLReader: { _ in
                XCTFail("Known workspace bundle should avoid application lookup")
                return nil
            }
        )

        XCTAssertEqual(
            service.audibleOutputProcesses().first?.name,
            "Workspace Bundle Display"
        )
    }

    @MainActor
    func testAudibleOutputProcessesFallsBackPastBlankBundleMetadata() throws {
        let bundle = try makeApplicationBundle(
            named: "Bundle Filename",
            info: [
                "CFBundleDisplayName": " \n",
                "CFBundleName": "",
            ]
        )
        let bundleIdentifier = "com.example.blank-bundle-metadata"
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: bundleIdentifier,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: { [] },
            applicationURLReader: { _ in bundle.bundleURL }
        )

        XCTAssertEqual(service.audibleOutputProcesses().first?.name, "Bundle Filename")
    }

    @MainActor
    func testAudibleOutputProcessesUsesLocalizedBundleDisplayName() throws {
        let bundle = try makeApplicationBundle(
            named: "Localized Bundle File",
            info: [
                "CFBundleDisplayName": "Raw Player",
                "CFBundleName": "Raw Name",
            ],
            localizedInfo: ["CFBundleDisplayName": "English Player"]
        )
        let bundleIdentifier = "com.example.localized-player"
        XCTAssertEqual(bundle.infoDictionary?["CFBundleDisplayName"] as? String, "Raw Player")
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            "English Player"
        )
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: bundleIdentifier,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: { [] },
            applicationURLReader: { _ in bundle.bundleURL }
        )

        XCTAssertEqual(service.audibleOutputProcesses().first?.name, "English Player")
    }

    func testLiveWorkspaceSnapshotLeavesMissingLocalizedNameForBundleResolution() throws {
        let source = try audioProcessServiceSource()

        XCTAssertTrue(source.contains("name: $0.localizedName ?? \"\""))
        XCTAssertFalse(source.contains("name: $0.localizedName ?? $0.bundleIdentifier"))
    }

    @MainActor
    func testAudibleOutputProcessesKeepsWorkspaceNameWhileResolvingMissingBundleURL() throws {
        let bundle = try makeApplicationBundle(
            named: "Resolver Fixture",
            info: ["CFBundleDisplayName": "Bundle Player"]
        )
        let bundleIdentifier = "com.example.workspace-player"
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: bundleIdentifier,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: {
                [
                    AudioProcessAppSnapshot(
                        processIdentifier: 101,
                        name: "Workspace Player",
                        bundleIdentifier: nil,
                        bundleURL: nil
                    ),
                ]
            },
            applicationURLReader: { identifier in
                identifier == bundleIdentifier ? bundle.bundleURL : nil
            }
        )

        let entry = try XCTUnwrap(service.audibleOutputProcesses().first)

        XCTAssertEqual(entry.name, "Workspace Player")
        XCTAssertEqual(entry.bundleIdentifier, bundleIdentifier)
        XCTAssertEqual(entry.bundleURL, bundle.bundleURL)
    }

    @MainActor
    func testAudibleOutputProcessesUsesBundleNameWhenDisplayNameIsUnavailable() throws {
        let bundle = try makeApplicationBundle(
            named: "Resolver Fixture",
            info: ["CFBundleName": "Bundle Player"]
        )
        let bundleIdentifier = "com.example.bundle-name"
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: bundleIdentifier,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: { [] },
            applicationURLReader: { _ in bundle.bundleURL }
        )

        XCTAssertEqual(service.audibleOutputProcesses().first?.name, "Bundle Player")
    }

    @MainActor
    func testAudibleOutputProcessesUsesBundleFilenameWhenBundleHasNoDisplayMetadata() throws {
        let bundle = try makeApplicationBundle(named: "Bundle Filename", info: [:])
        let bundleIdentifier = "com.example.bundle-filename"
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: bundleIdentifier,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: { [] },
            applicationURLReader: { _ in bundle.bundleURL }
        )

        XCTAssertEqual(service.audibleOutputProcesses().first?.name, "Bundle Filename")
    }

    @MainActor
    func testAudibleOutputProcessesKeepsHonestFallbacksAndExcludesOwnPIDBeforeResolution() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let unresolvedPID = ownPID + 1
        let processPID = ownPID + 2
        let nonFilePID = ownPID + 3
        let dormantPID = ownPID + 4
        var resolvedIdentifiers: [String] = []
        var executablePIDs: [pid_t] = []
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: ownPID,
                        bundleIdentifier: "com.example.self",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 12,
                        processIdentifier: unresolvedPID,
                        bundleIdentifier: "com.example.unresolved",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 13,
                        processIdentifier: processPID,
                        bundleIdentifier: nil,
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 14,
                        processIdentifier: nonFilePID,
                        bundleIdentifier: "com.example.non-file",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 15,
                        processIdentifier: dormantPID,
                        bundleIdentifier: "com.example.dormant",
                        isRunningOutput: false
                    ),
                ]
            },
            appSnapshotReader: { [] },
            applicationURLReader: { identifier in
                resolvedIdentifiers.append(identifier)
                return nil
            },
            processExecutableURLReader: { processIdentifier in
                executablePIDs.append(processIdentifier)
                switch processIdentifier {
                case unresolvedPID:
                    return URL(fileURLWithPath: "/tmp/not-an-application")
                case processPID:
                    return nil
                case nonFilePID:
                    return URL(string: "https://example.invalid/process")
                default:
                    XCTFail("Only audible non-self process IDs may be looked up")
                    return nil
                }
            }
        )

        let entriesByObjectID = Dictionary(
            uniqueKeysWithValues: service.audibleOutputProcesses().map { ($0.processObjectID, $0) }
        )

        XCTAssertEqual(
            resolvedIdentifiers,
            ["com.example.unresolved", "com.example.non-file"]
        )
        XCTAssertEqual(executablePIDs, [unresolvedPID, processPID, nonFilePID])
        XCTAssertNil(entriesByObjectID[11])
        XCTAssertEqual(entriesByObjectID[12]?.name, "com.example.unresolved")
        XCTAssertEqual(entriesByObjectID[12]?.bundleIdentifier, "com.example.unresolved")
        XCTAssertNil(entriesByObjectID[12]?.bundleURL)
        XCTAssertEqual(entriesByObjectID[13]?.name, "Process \(processPID)")
        XCTAssertNil(entriesByObjectID[13]?.bundleIdentifier)
        XCTAssertNil(entriesByObjectID[13]?.bundleURL)
        XCTAssertEqual(entriesByObjectID[14]?.name, "com.example.non-file")
        XCTAssertEqual(entriesByObjectID[14]?.bundleIdentifier, "com.example.non-file")
        XCTAssertNil(entriesByObjectID[14]?.bundleURL)
    }

    @MainActor
    func testAudibleOutputProcessesResolvesMissingHelperMetadataFromContainingApplicationBundle() throws {
        let edgeBundle = try makeApplicationBundle(
            named: "Microsoft Edge",
            info: ["CFBundleDisplayName": "Microsoft Edge"]
        )
        let helperBundleIdentifier = "com.microsoft.edgemac.helper"
        let helperPID: pid_t = 97_526
        let staleHelperExecutableURL = edgeBundle.bundleURL
            .appendingPathComponent("Contents/Frameworks/Microsoft Edge Framework.framework")
            .appendingPathComponent("Versions/151.0.4129.86/Helpers/Microsoft Edge Helper.app")
            .appendingPathComponent("Contents/MacOS/Microsoft Edge Helper")
        var resolvedIdentifiers: [String] = []
        var executablePIDs: [pid_t] = []
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 121,
                        processIdentifier: helperPID,
                        bundleIdentifier: helperBundleIdentifier,
                        isRunningOutput: true,
                        outputDeviceIDs: [82]
                    ),
                ]
            },
            appSnapshotReader: { [] },
            applicationURLReader: { identifier in
                resolvedIdentifiers.append(identifier)
                return nil
            },
            processExecutableURLReader: { processIdentifier in
                executablePIDs.append(processIdentifier)
                return processIdentifier == helperPID ? staleHelperExecutableURL : nil
            }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleHelperExecutableURL.path))

        let entry = try XCTUnwrap(service.audibleOutputProcesses().first)

        XCTAssertEqual(resolvedIdentifiers, [helperBundleIdentifier])
        XCTAssertEqual(executablePIDs, [helperPID])
        XCTAssertEqual(entry.processObjectID, 121)
        XCTAssertEqual(entry.processIdentifier, helperPID)
        XCTAssertEqual(entry.bundleIdentifier, helperBundleIdentifier)
        XCTAssertEqual(entry.outputDeviceIDs, [82])
        XCTAssertEqual(entry.name, "Microsoft Edge")
        XCTAssertEqual(entry.bundleURL, edgeBundle.bundleURL)
    }

    @MainActor
    func testAudibleOutputProcessesUsesWorkspaceIdentifierWhenMetadataCannotResolve() throws {
        let bundleIdentifier = "com.example.workspace-unresolved"
        var resolvedIdentifiers: [String] = []
        let service = AudioProcessService(
            availability: .init(operatingSystemVersion: .init(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )),
            processSnapshotReader: {
                [
                    AudioProcessSnapshot(
                        processObjectID: 11,
                        processIdentifier: 101,
                        bundleIdentifier: nil,
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: {
                [
                    AudioProcessAppSnapshot(
                        processIdentifier: 101,
                        name: "",
                        bundleIdentifier: bundleIdentifier,
                        bundleURL: nil
                    ),
                ]
            },
            applicationURLReader: { identifier in
                resolvedIdentifiers.append(identifier)
                return nil
            }
        )

        let entry = try XCTUnwrap(service.audibleOutputProcesses().first)

        XCTAssertEqual(resolvedIdentifiers, [bundleIdentifier])
        XCTAssertEqual(entry.name, bundleIdentifier)
        XCTAssertEqual(entry.bundleIdentifier, bundleIdentifier)
        XCTAssertNil(entry.bundleURL)
    }

    @MainActor
    func testAudibleOutputProcessesSortInjectedEntriesCaseInsensitively() {
        let service = AudioProcessService(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(
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
                        bundleIdentifier: "com.example.Zebra",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 12,
                        processIdentifier: 102,
                        bundleIdentifier: "com.example.Alpha",
                        isRunningOutput: true
                    ),
                    AudioProcessSnapshot(
                        processObjectID: 13,
                        processIdentifier: 103,
                        bundleIdentifier: "com.example.Music",
                        isRunningOutput: true
                    ),
                ]
            },
            appSnapshotReader: {
                [
                    AudioProcessAppSnapshot(
                        processIdentifier: 101,
                        name: "zebra",
                        bundleIdentifier: "com.example.Zebra",
                        bundleURL: nil
                    ),
                    AudioProcessAppSnapshot(
                        processIdentifier: 102,
                        name: "Alpha",
                        bundleIdentifier: "com.example.Alpha",
                        bundleURL: nil
                    ),
                    AudioProcessAppSnapshot(
                        processIdentifier: 103,
                        name: "music",
                        bundleIdentifier: "com.example.Music",
                        bundleURL: nil
                    ),
                ]
            }
        )

        XCTAssertEqual(
            service.audibleOutputProcesses().map(\.name),
            ["Alpha", "music", "zebra"]
        )
    }

    private func makeApplicationBundle(
        named name: String,
        info: [String: String],
        localizedInfo: [String: String] = [:]
    ) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist = NSMutableDictionary(dictionary: [
            "CFBundleExecutable": "Fixture",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "APPL",
        ])
        infoPlist.addEntries(from: info)
        XCTAssertTrue(infoPlist.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            atomically: true
        ))
        if !localizedInfo.isEmpty {
            let localizationURL = contentsURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("en.lproj")
            try FileManager.default.createDirectory(at: localizationURL, withIntermediateDirectories: true)
            let contents = localizedInfo.map { "\"\($0.key)\" = \"\($0.value)\";" }
                .sorted()
                .joined(separator: "\n")
            try contents.write(
                to: localizationURL.appendingPathComponent("InfoPlist.strings"),
                atomically: true,
                encoding: .utf8
            )
        }
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func audioProcessServiceSource() throws -> String {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MacActivityCore/Audio/AudioProcessService.swift"
            ),
            encoding: .utf8
        )
    }
}
