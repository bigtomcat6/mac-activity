import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testRefreshPrimesAndPublishesFollowUpEnergyImpactSample() async {
        let baseline = entry(power: 0)
        let ranked = entry(power: 8.4)
        let provider = EnergyImpactProviderStub(responses: [[baseline], [ranked]])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            samplingDelayNanoseconds: 1,
            sleep: { _ in }
        )

        await model.refresh()

        XCTAssertEqual(model.entries.map(\.name), ["Safari"])
        XCTAssertEqual(model.entries.first?.currentPowerMicrowatts, 8.4)
        XCTAssertEqual(provider.requestedLimits, [20, 20])
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshClearsRefreshingWhenSamplingSleepThrows() async {
        let provider = EnergyImpactProviderStub(responses: [[]])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            samplingDelayNanoseconds: 1,
            sleep: { _ in throw CancellationError() }
        )

        await model.refresh()

        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(provider.requestedLimits, [20])
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshWithDefaultSleepCanUseZeroSamplingDelay() async {
        let provider = EnergyImpactProviderStub(responses: [[], []])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 1,
            samplingDelayNanoseconds: 0
        )

        await model.refresh()

        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(provider.requestedLimits, [1, 1])
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshWhileVisibleReturnsWhenInitialRefreshCancelsTask() async {
        let provider = EnergyImpactProviderStub(responses: [[]])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            samplingDelayNanoseconds: 1,
            sleep: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )

        let task = Task {
            await model.refreshWhileVisible(refreshIntervalNanoseconds: 3)
        }
        await task.value

        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(provider.requestedLimits, [20])
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshWhileVisibleRepeatsAfterVisibleRefreshInterval() async {
        let provider = EnergyImpactProviderStub(responses: [[entry(power: 0)], [entry(power: 3.2)], [entry(power: 7.6)]])
        var requestedSleeps: [UInt64] = []
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            samplingDelayNanoseconds: 1,
            sleep: { duration in
                requestedSleeps.append(duration)
                guard requestedSleeps != [1, 3, 3] else {
                    throw CancellationError()
                }
            }
        )

        await model.refreshWhileVisible(refreshIntervalNanoseconds: 3)

        XCTAssertEqual(model.entries.map(\.currentPowerMicrowatts), [7.6])
        XCTAssertEqual(provider.requestedLimits, [20, 20, 20])
        XCTAssertEqual(requestedSleeps, [1, 3, 3])
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(provider.topApps(limit: 20), [])
    }

    private func entry(power: Double) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: 101,
                rootProcessStartAbsoluteTime: 1
            ),
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            currentPowerMicrowatts: power,
            sustainedPowerMicrowatts: power,
            rankingScore: power,
            trend: .steady,
            coverage: .unavailable,
            status: .stable
        )
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
