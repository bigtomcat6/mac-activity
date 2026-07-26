import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testRefreshWhileVisibleWaitsFullWindowAndSmoothsEveryPublishedSample() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(power: 0)],
                [entry(power: 100)],
                [entry(power: 0)]
            ]
        )
        var requestedSleeps: [UInt64] = []
        var model: EnergyImpactModel!
        model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            clock: clock,
            sleep: { duration in
                requestedSleeps.append(duration)
                if requestedSleeps.count == 1 {
                    XCTAssertTrue(model.entries.isEmpty)
                }
                guard requestedSleeps.count < 3 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(requestedSleeps, [3_000_000_000, 3_000_000_000, 3_000_000_000])
        XCTAssertEqual(provider.requestedLimits, [.max, .max, .max])
        XCTAssertEqual(
            try XCTUnwrap(model.entries.first?.currentPowerMicrowatts),
            59.460_355_75,
            accuracy: 0.000_001
        )
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshClearsRefreshingWhenInitialWindowSleepThrows() async {
        let provider = EnergyImpactProviderStub(responses: [[]])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            initialWindowNanoseconds: 3_000_000_000,
            sleep: { _ in throw CancellationError() }
        )

        await model.refresh()

        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(provider.requestedLimits, [.max])
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshWhileVisibleReturnsWhenInitialRefreshCancelsTask() async {
        let provider = EnergyImpactProviderStub(responses: [[]])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            initialWindowNanoseconds: 3_000_000_000,
            sleep: { _ in
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )

        let task = Task {
            await model.refreshWhileVisible()
        }
        await task.value

        XCTAssertEqual(model.entries, [])
        XCTAssertEqual(provider.requestedLimits, [.max])
        XCTAssertFalse(model.isRefreshing)
    }

    func testPIDReuseStartsReplacementGenerationFromItsOwnRawValue() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(power: 0, startTime: 10)],
                [entry(power: 100, startTime: 10)],
                [entry(power: 5, startTime: 20)]
            ]
        )
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount < 3 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        let replacement = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(replacement.identity.rootProcessStartAbsoluteTime, 20)
        XCTAssertEqual(replacement.currentPowerMicrowatts, 5)
    }

    func testMissingGenerationPublishesRawValuesWithoutRetainingEMAState() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(power: 0, startTime: nil)],
                [entry(power: 100, startTime: nil)],
                [entry(power: 0, startTime: nil)]
            ]
        )
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount < 3 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(try XCTUnwrap(model.entries.first?.currentPowerMicrowatts), 0)
    }

    func testStalePublicationDoesNotAdvanceEMARecoveryTime() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(power: 0)],
                [entry(power: 100)],
                [entry(power: 100, status: .stale)],
                [entry(power: 0)]
            ]
        )
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount < 4 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(
            try XCTUnwrap(model.entries.first?.currentPowerMicrowatts),
            35.355_339_06,
            accuracy: 0.000_001
        )
    }

    func testStalePublicationInterruptsRankConfirmation() async {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(pid: 1, power: 0), entry(pid: 2, power: 0)],
                [entry(pid: 1, power: 100), entry(pid: 2, power: 90)],
                [entry(pid: 1, power: 100), entry(pid: 2, power: 145)],
                [entry(pid: 1, power: 100), entry(pid: 2, power: 145, status: .stale)],
                [entry(pid: 1, power: 100), entry(pid: 2, power: 112)],
                [entry(pid: 1, power: 100), entry(pid: 2, power: 112)]
            ]
        )
        var ordersBeforeSleep: [[pid_t]] = []
        var sleepCount = 0
        var model: EnergyImpactModel!
        model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                if model.entries.isEmpty == false {
                    ordersBeforeSleep.append(model.entries.map(\.processIdentifier))
                }
                guard sleepCount < 6 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(
            ordersBeforeSleep,
            [
                [1, 2],
                [1, 2],
                [1, 2],
                [1, 2],
                [2, 1]
            ]
        )
    }

    func testAllCandidatesAreSmoothedBeforeTopLimitIsApplied() async throws {
        let clock = EnergyImpactTestClock()
        let steady = (1...20).map { entry(pid: pid_t($0), power: 50) }
        let lowCandidate = entry(pid: 21, power: 0)
        let highCandidate = entry(pid: 21, power: 100)
        let provider = EnergyImpactProviderStub(
            responses: [
                steady + [lowCandidate],
                steady + [lowCandidate],
                steady + [highCandidate],
                steady + [highCandidate]
            ]
        )
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            limit: 20,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount < 4 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(provider.requestedLimits, [.max, .max, .max, .max])
        let candidate = try XCTUnwrap(
            model.entries.first { $0.processIdentifier == 21 }
        )
        XCTAssertEqual(
            try XCTUnwrap(candidate.currentPowerMicrowatts),
            64.644_660_94,
            accuracy: 0.000_001
        )
        XCTAssertEqual(model.entries.count, 20)
    }

    func testLongGapClearsPreviousSmoothingState() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(power: 0)],
                [entry(power: 100)],
                [entry(power: 0)]
            ]
        )
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount < 3 else { throw CancellationError() }
                clock.advance(seconds: sleepCount == 1 ? 3 : 11)
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(try XCTUnwrap(model.entries.first?.currentPowerMicrowatts), 0)
    }

    func testInvalidCurrentValuePublishesNonnumericUnavailableAndDoesNotAdvanceEMA() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(power: 0)],
                [entry(power: 100)],
                [entry(power: .nan)],
                [entry(power: 0)]
            ]
        )
        var sleepCount = 0
        var invalidPublication: EnergyImpactEntry?
        var model: EnergyImpactModel!
        model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 3 {
                    invalidPublication = model.entries.first
                }
                guard sleepCount < 4 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        let invalid = try XCTUnwrap(invalidPublication)
        XCTAssertNil(invalid.currentPowerMicrowatts)
        XCTAssertNil(invalid.rankingScore)
        XCTAssertEqual(invalid.status, .unavailable)
        XCTAssertEqual(
            try XCTUnwrap(model.entries.first?.currentPowerMicrowatts),
            35.355_339_06,
            accuracy: 0.000_001
        )
    }
}

private func entry(
    pid: pid_t = 101,
    power: Double?,
    startTime: UInt64? = 1,
    status: EnergyImpactStatus = .stable
) -> EnergyImpactEntry {
    EnergyImpactEntry(
        identity: EnergyImpactAppIdentity(
            rootProcessIdentifier: pid,
            rootProcessStartAbsoluteTime: startTime
        ),
        name: "App \(pid)",
        bundleIdentifier: "com.example.app-\(pid)",
        bundleURL: nil,
        currentPowerMicrowatts: power,
        sustainedPowerMicrowatts: power,
        rankingScore: power,
        trend: .steady,
        coverage: EnergyImpactCoverage(
            discoveredProcessCount: 1,
            readableProcessCount: 1,
            validProcessSeconds: status == .stable || status == .partial ? 3 : 0,
            discoveredProcessSeconds: 3
        ),
        status: status
    )
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
        guard responses.isEmpty == false else { return [] }
        return Array(responses.removeFirst().prefix(limit))
    }
}

private final class EnergyImpactTestClock: EnergyImpactClock, @unchecked Sendable {
    private var value: TimeInterval = 0

    func nowSeconds() -> TimeInterval {
        value
    }

    func advance(seconds: TimeInterval) {
        value += seconds
    }
}
