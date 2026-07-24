import Darwin
import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactProviderTests: XCTestCase {
    func testEnergyImpactEntryRepresentsCollectingWithoutAFalseZero() {
        let entry = EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: 101,
                rootProcessStartAbsoluteTime: 10
            ),
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            currentPowerMicrowatts: nil,
            sustainedPowerMicrowatts: nil,
            rankingScore: nil,
            trend: .steady,
            coverage: EnergyImpactCoverage(
                discoveredProcessCount: 1,
                readableProcessCount: 1,
                validProcessSeconds: 0,
                discoveredProcessSeconds: 0
            ),
            status: .collecting
        )

        XCTAssertNil(entry.displayPowerMicrowatts)
        XCTAssertEqual(entry.status, .collecting)
    }

    func testEnergyImpactCoverageUsesValidPIDTime() {
        let coverage = EnergyImpactCoverage(
            discoveredProcessCount: 4,
            readableProcessCount: 3,
            validProcessSeconds: 9,
            discoveredProcessSeconds: 12
        )

        XCTAssertEqual(coverage.fraction, 0.75, accuracy: 0.001)
    }

    func testEnergyImpactCoverageIsZeroWithoutDiscoveredPIDTime() {
        let coverage = EnergyImpactCoverage(
            discoveredProcessCount: 0,
            readableProcessCount: 0,
            validProcessSeconds: 0,
            discoveredProcessSeconds: 0
        )

        XCTAssertEqual(coverage.fraction, 0)
    }

    func testEnergyImpactServiceReportsPartialCoverageWhenOneDescendantHasNoValidDelta() throws {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Browser",
            bundleIdentifier: "com.example.browser",
            bundleURL: nil
        )
        let service = EnergyImpactService(
            reader: ProcessEnergyReadingProviderStub(readings: [
                100: [
                    .init(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                    .init(energyNanojoules: 2_000, processStartAbsoluteTime: 10),
                ],
                101: [
                    .init(energyNanojoules: 2_000, processStartAbsoluteTime: 11),
                    .init(energyNanojoules: 3_000, processStartAbsoluteTime: 21),
                ],
            ]),
            processSnapshotReader: ProcessMemorySnapshotReaderStub(snapshots: [
                .init(processIdentifier: 101, parentProcessIdentifier: 100, residentMemoryBytes: 0),
            ]),
            appSnapshotProvider: { [app] },
            now: dateSequence([100, 101])
        )

        _ = service.topApps(limit: 1)
        let entry = try XCTUnwrap(service.topApps(limit: 1).first)

        XCTAssertEqual(entry.status, .partial)
        XCTAssertEqual(entry.coverage.validProcessSeconds, 1)
        XCTAssertEqual(entry.coverage.discoveredProcessSeconds, 2)
        XCTAssertEqual(entry.coverage.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(entry.currentPowerMicrowatts), 1, accuracy: 0.001)
    }

    func testSystemProcessEnergyReaderReadsCurrentProcess() throws {
        let reading = try XCTUnwrap(SystemProcessEnergyReader().reading(for: getpid()))

        XCTAssertGreaterThan(reading.processStartAbsoluteTime, 0)
    }

    func testDefaultWorkspaceSnapshotProviderBuildsEntriesFromRunningApplications() {
        let service = EnergyImpactService(
            reader: ProcessEnergyReadingProviderStub(readings: [:]),
            processSnapshotReader: ProcessMemorySnapshotReaderStub(snapshots: [])
        )
        let entries = service.topApps(limit: 1)

        XCTAssertLessThanOrEqual(entries.count, 1)
    }

    func testEnergyImpactServiceUsesPreviousRefreshSnapshotsForImpact() throws {
        let apps = [
            EnergyImpactAppSnapshot(
                processIdentifier: 101,
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
            ),
            EnergyImpactAppSnapshot(
                processIdentifier: 102,
                name: "Notes",
                bundleIdentifier: "com.apple.Notes",
                bundleURL: URL(fileURLWithPath: "/Applications/Notes.app")
            ),
        ]
        let reader = ProcessEnergyReadingProviderStub(readings: [
            101: [
                ProcessEnergyReading(energyNanojoules: 1_000),
                ProcessEnergyReading(energyNanojoules: 3_500),
            ],
            102: [
                ProcessEnergyReading(energyNanojoules: 2_000),
                ProcessEnergyReading(energyNanojoules: 2_300),
            ],
        ])
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessMemorySnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { apps },
            now: dateSequence([100, 101])
        )

        let firstEntries = service.topApps(limit: 2)
        let secondEntries = service.topApps(limit: 2)

        XCTAssertTrue(firstEntries.allSatisfy { $0.status == .collecting })
        XCTAssertTrue(firstEntries.allSatisfy { $0.currentPowerMicrowatts == nil })
        XCTAssertEqual(secondEntries.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(try XCTUnwrap(secondEntries[0].currentPowerMicrowatts), 2.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(secondEntries[1].currentPowerMicrowatts), 0.3, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 101), 2)
        XCTAssertEqual(reader.readCount(for: 102), 2)
    }

    func testEnergyImpactServiceNormalizesImpactByElapsedTime() throws {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 101,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
        )
        let reader = ProcessEnergyReadingProviderStub(readings: [
            101: [
                ProcessEnergyReading(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                ProcessEnergyReading(energyNanojoules: 3_500, processStartAbsoluteTime: 10),
            ],
        ])
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessMemorySnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [app] },
            now: dateSequence([100, 100.5])
        )

        _ = service.topApps(limit: 1)
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(try XCTUnwrap(entries.first?.currentPowerMicrowatts), 5.0, accuracy: 0.001)
    }

    func testEnergyImpactServiceAggregatesDescendantEnergyIntoOwningApp() throws {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 100,
            name: "Browser",
            bundleIdentifier: "com.example.browser",
            bundleURL: URL(fileURLWithPath: "/Applications/Browser.app")
        )
        let reader = ProcessEnergyReadingProviderStub(readings: [
            100: [
                ProcessEnergyReading(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                ProcessEnergyReading(energyNanojoules: 2_000, processStartAbsoluteTime: 10),
            ],
            101: [
                ProcessEnergyReading(energyNanojoules: 2_000, processStartAbsoluteTime: 11),
                ProcessEnergyReading(energyNanojoules: 5_000, processStartAbsoluteTime: 11),
            ],
            102: [
                ProcessEnergyReading(energyNanojoules: 100, processStartAbsoluteTime: 12),
                ProcessEnergyReading(energyNanojoules: 1_100, processStartAbsoluteTime: 12),
            ],
        ])
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessMemorySnapshotReaderStub(snapshots: [
                ProcessMemorySnapshot(processIdentifier: 100, parentProcessIdentifier: 1, residentMemoryBytes: 0),
                ProcessMemorySnapshot(processIdentifier: 101, parentProcessIdentifier: 100, residentMemoryBytes: 0),
                ProcessMemorySnapshot(processIdentifier: 102, parentProcessIdentifier: 101, residentMemoryBytes: 0),
                ProcessMemorySnapshot(processIdentifier: 999, parentProcessIdentifier: 1, residentMemoryBytes: 0),
            ]),
            appSnapshotProvider: { [app] },
            now: dateSequence([100, 102])
        )

        _ = service.topApps(limit: 1)
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(try XCTUnwrap(entries.first?.currentPowerMicrowatts), 2.5, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 100), 2)
        XCTAssertEqual(reader.readCount(for: 101), 2)
        XCTAssertEqual(reader.readCount(for: 102), 2)
        XCTAssertEqual(reader.readCount(for: 999), 0)
    }

    func testEnergyImpactServiceRejectsDeltasWhenPIDIsReused() {
        let app = EnergyImpactAppSnapshot(
            processIdentifier: 101,
            name: "Reused",
            bundleIdentifier: "com.example.reused",
            bundleURL: nil
        )
        let reader = ProcessEnergyReadingProviderStub(readings: [
            101: [
                ProcessEnergyReading(energyNanojoules: 1_000, processStartAbsoluteTime: 10),
                ProcessEnergyReading(energyNanojoules: 50_000, processStartAbsoluteTime: 20),
            ],
        ])
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessMemorySnapshotReaderStub(snapshots: []),
            appSnapshotProvider: { [app] },
            now: dateSequence([100, 101])
        )

        _ = service.topApps(limit: 1)
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(entries.first?.status, .collecting)
        XCTAssertNil(entries.first?.currentPowerMicrowatts)
    }

    func testEnergyImpactServiceKeepsUnreadableAppsAsUnavailableRows() {
        let reader = ProcessEnergyReadingProviderStub(readings: [:])
        let service = EnergyImpactService(
            reader: reader,
            processSnapshotReader: ProcessMemorySnapshotReaderStub(snapshots: []),
            appSnapshotProvider: {
                [
                    EnergyImpactAppSnapshot(
                        processIdentifier: 101,
                        name: "Locked App",
                        bundleIdentifier: nil,
                        bundleURL: nil
                    ),
                ]
            }
        )
        let entries = service.topApps(limit: 1)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Locked App")
        XCTAssertNil(entries[0].currentPowerMicrowatts)
        XCTAssertEqual(entries[0].status, .unavailable)
    }

    func testEnergyImpactEntriesSortTiesByName() {
        let entries = [
            EnergyImpactEntry(
                identity: EnergyImpactAppIdentity(
                    rootProcessIdentifier: 101,
                    rootProcessStartAbsoluteTime: 10
                ),
                name: "Notes",
                bundleIdentifier: "com.apple.Notes",
                bundleURL: nil,
                currentPowerMicrowatts: 4.2,
                sustainedPowerMicrowatts: nil,
                rankingScore: 4.2,
                trend: .steady,
                coverage: .unavailable,
                status: .stable
            ),
            EnergyImpactEntry(
                identity: EnergyImpactAppIdentity(
                    rootProcessIdentifier: 102,
                    rootProcessStartAbsoluteTime: 11
                ),
                name: "Calendar",
                bundleIdentifier: "com.apple.iCal",
                bundleURL: nil,
                currentPowerMicrowatts: 4.2,
                sustainedPowerMicrowatts: nil,
                rankingScore: 4.2,
                trend: .steady,
                coverage: .unavailable,
                status: .stable
            ),
        ]

        XCTAssertEqual(EnergyImpactService.sortedByImpact(entries, limit: 2).map(\.name), ["Calendar", "Notes"])
    }
}

private func dateSequence(_ offsets: [TimeInterval]) -> () -> Date {
    var remainingOffsets = offsets
    return {
        let offset = remainingOffsets.isEmpty ? offsets.last ?? 0 : remainingOffsets.removeFirst()
        return Date(timeIntervalSinceReferenceDate: offset)
    }
}

private final class ProcessEnergyReadingProviderStub: ProcessEnergyReadingProvider, @unchecked Sendable {
    private var readings: [pid_t: [ProcessEnergyReading]]
    private var readCounts: [pid_t: Int] = [:]

    init(readings: [pid_t: [ProcessEnergyReading]]) {
        self.readings = readings
    }

    func reading(for processIdentifier: pid_t) -> ProcessEnergyReading? {
        readCounts[processIdentifier, default: 0] += 1
        guard var values = readings[processIdentifier], values.isEmpty == false else {
            return nil
        }
        let value = values.removeFirst()
        readings[processIdentifier] = values
        return value
    }

    func readCount(for processIdentifier: pid_t) -> Int {
        readCounts[processIdentifier, default: 0]
    }
}

private struct ProcessMemorySnapshotReaderStub: ProcessMemorySnapshotReading {
    let snapshotValues: [ProcessMemorySnapshot]

    init(snapshots: [ProcessMemorySnapshot]) {
        self.snapshotValues = snapshots
    }

    func snapshots() -> [ProcessMemorySnapshot] {
        snapshotValues
    }
}
