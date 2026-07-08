import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testRefreshLoadsEnergyImpactEntries() {
        let provider = EnergyImpactProviderStub(entries: [
            EnergyImpactEntry(
                processIdentifier: 101,
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundleURL: nil,
                impact: 8.4,
                isReadable: true
            )
        ])
        let model = EnergyImpactModel(provider: provider, limit: 20)

        model.refresh()

        XCTAssertEqual(model.entries.map(\.name), ["Safari"])
        XCTAssertEqual(provider.requestedLimits, [20])
        XCTAssertFalse(model.isRefreshing)
    }
}

@MainActor
private final class EnergyImpactProviderStub: EnergyImpactProviding {
    let entries: [EnergyImpactEntry]
    private(set) var requestedLimits: [Int] = []

    init(entries: [EnergyImpactEntry]) {
        self.entries = entries
    }

    func topApps(limit: Int) -> [EnergyImpactEntry] {
        requestedLimits.append(limit)
        return Array(entries.prefix(limit))
    }
}
