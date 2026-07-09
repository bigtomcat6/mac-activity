import XCTest
@testable import MacActivityCore

@MainActor
final class EnergyImpactProviderTests: XCTestCase {
    func testEnergyImpactServiceUsesPreviousRefreshSnapshotsForImpact() {
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

        XCTAssertEqual(firstEntries.map(\.impact), [0, 0])
        XCTAssertTrue(firstEntries.allSatisfy(\.isReadable))
        XCTAssertEqual(secondEntries.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(secondEntries[0].impact, 2.5, accuracy: 0.001)
        XCTAssertEqual(secondEntries[1].impact, 0.3, accuracy: 0.001)
        XCTAssertEqual(reader.readCount(for: 101), 2)
        XCTAssertEqual(reader.readCount(for: 102), 2)
    }

    func testEnergyImpactServiceNormalizesImpactByElapsedTime() {
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

        XCTAssertEqual(entries.first?.impact ?? 0, 5.0, accuracy: 0.001)
    }

    func testEnergyImpactServiceAggregatesDescendantEnergyIntoOwningApp() {
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

        XCTAssertEqual(entries.first?.impact ?? 0, 2.5, accuracy: 0.001)
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

        XCTAssertEqual(entries.first?.impact ?? 0, 0, accuracy: 0.001)
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
        XCTAssertEqual(entries[0].impact, 0)
        XCTAssertFalse(entries[0].isReadable)
    }

    func testEnergyImpactEntriesSortTiesByName() {
        let entries = [
            EnergyImpactEntry(
                processIdentifier: 101,
                name: "Notes",
                bundleIdentifier: "com.apple.Notes",
                bundleURL: nil,
                impact: 4.2,
                isReadable: true
            ),
            EnergyImpactEntry(
                processIdentifier: 102,
                name: "Calendar",
                bundleIdentifier: "com.apple.iCal",
                bundleURL: nil,
                impact: 4.2,
                isReadable: true
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
