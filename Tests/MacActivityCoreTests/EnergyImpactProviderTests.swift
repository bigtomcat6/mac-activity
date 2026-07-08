import XCTest
@testable import MacActivityCore

final class EnergyImpactProviderTests: XCTestCase {
    func testEnergyImpactServiceRanksByPositiveEnergyDelta() {
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

        let entries = EnergyImpactService.energyEntries(
            apps: [
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
            ],
            reader: reader,
            limit: 2
        )

        XCTAssertEqual(entries.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(entries[0].impact, 2.5, accuracy: 0.001)
        XCTAssertTrue(entries[0].isReadable)
    }

    func testEnergyImpactServiceKeepsUnreadableAppsAsUnavailableRows() {
        let reader = ProcessEnergyReadingProviderStub(readings: [:])

        let entries = EnergyImpactService.energyEntries(
            apps: [
                EnergyImpactAppSnapshot(
                    processIdentifier: 101,
                    name: "Locked App",
                    bundleIdentifier: nil,
                    bundleURL: nil
                ),
            ],
            reader: reader,
            limit: 1
        )

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

    init(readings: [pid_t: [ProcessEnergyReading]]) {
        self.readings = readings
    }

    func reading(for processIdentifier: pid_t) -> ProcessEnergyReading? {
        guard var values = readings[processIdentifier], values.isEmpty == false else {
            return nil
        }
        let value = values.removeFirst()
        readings[processIdentifier] = values
        return value
    }
}
