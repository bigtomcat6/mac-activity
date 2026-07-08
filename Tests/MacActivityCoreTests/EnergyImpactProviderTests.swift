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
            appSnapshotProvider: { apps }
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

    func testEnergyImpactServiceKeepsUnreadableAppsAsUnavailableRows() {
        let reader = ProcessEnergyReadingProviderStub(readings: [:])
        let service = EnergyImpactService(
            reader: reader,
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
