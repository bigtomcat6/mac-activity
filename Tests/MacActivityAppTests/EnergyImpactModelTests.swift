import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testRefreshPrimesAndPublishesFollowUpEnergyImpactSample() async {
        let baseline = EnergyImpactEntry(
            processIdentifier: 101,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            impact: 0,
            isReadable: true
        )
        let ranked = EnergyImpactEntry(
            processIdentifier: 101,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            impact: 8.4,
            isReadable: true
        )
        let provider = EnergyImpactProviderStub(responses: [[baseline], [ranked]])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            samplingDelayNanoseconds: 1,
            sleep: { _ in }
        )

        await model.refresh()

        XCTAssertEqual(model.entries.map(\.name), ["Safari"])
        XCTAssertEqual(model.entries.first?.impact, 8.4)
        XCTAssertEqual(provider.requestedLimits, [20, 20])
        XCTAssertFalse(model.isRefreshing)
    }
}

@MainActor
private final class EnergyImpactProviderStub: EnergyImpactProviding {
    private var responses: [[EnergyImpactEntry]]
    private(set) var requestedLimits: [Int] = []

    init(responses: [[EnergyImpactEntry]]) {
        self.responses = responses
    }

    func topApps(limit: Int) -> [EnergyImpactEntry] {
        requestedLimits.append(limit)
        guard responses.isEmpty == false else {
            return []
        }
        return Array(responses.removeFirst().prefix(limit))
    }
}
