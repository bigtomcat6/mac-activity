import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testRefreshUsesDefaultSleepImplementation() async throws {
        let model = EnergyImpactModel(
            provider: EnergyImpactProviderStub(
                responses: [
                    [],
                    [entry(power: 1)],
                ]
            ),
            initialWindowNanoseconds: 0
        )

        await model.refresh()

        XCTAssertEqual(try XCTUnwrap(model.entries.first?.currentPowerMicrowatts), 1)
    }

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

    func testNumericStaleEntryRemainsInTopTwentyAheadOfCollectingEntries() async throws {
        let stale = EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: 101,
                rootProcessStartAbsoluteTime: 1
            ),
            name: "Stale",
            bundleIdentifier: "com.example.stale",
            bundleURL: nil,
            currentPowerMicrowatts: 100,
            sustainedPowerMicrowatts: nil,
            rankingScore: nil,
            trend: .steady,
            coverage: EnergyImpactCoverage(
                discoveredProcessCount: 1,
                readableProcessCount: 1,
                validProcessSeconds: 3,
                discoveredProcessSeconds: 3
            ),
            status: .stale
        )
        let collecting = (1...20).map {
            entry(pid: pid_t(200 + $0), power: nil, status: .collecting)
        }
        let provider = EnergyImpactProviderStub(responses: [[], collecting + [stale]])
        let model = EnergyImpactModel(provider: provider, limit: 20, sleep: { _ in })

        await model.refresh()

        XCTAssertEqual(model.entries.count, 20)
        let publishedStale = try XCTUnwrap(
            model.entries.first { $0.processIdentifier == stale.processIdentifier }
        )
        XCTAssertEqual(model.entries.first?.processIdentifier, stale.processIdentifier)
        XCTAssertEqual(publishedStale.status, .stale)
        XCTAssertEqual(publishedStale.currentPowerMicrowatts, 100)
        XCTAssertNil(publishedStale.rankingScore)
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

    func testStableEntryWithMissingNumericFieldsPublishesUnavailable() async throws {
        let clock = EnergyImpactTestClock()
        let model = EnergyImpactModel(
            provider: EnergyImpactProviderStub(
                responses: [
                    [],
                    [entry(power: nil, status: .stable)],
                ]
            ),
            clock: clock,
            sleep: { _ in clock.advance(seconds: 3) }
        )

        await model.refresh()

        let unavailable = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertNil(unavailable.currentPowerMicrowatts)
        XCTAssertNil(unavailable.rankingScore)
    }

    func testSmoothingFailurePublishesNonnumericUnavailable() async throws {
        let clock = EnergyImpactTestClock()
        let model = EnergyImpactModel(
            provider: EnergyImpactProviderStub(
                responses: [
                    [],
                    [entry(power: 100)],
                ]
            ),
            clock: clock,
            smoothingOverrideForTesting: { _, _, _ in nil },
            sleep: { _ in clock.advance(seconds: 3) }
        )

        await model.refresh()

        let unavailable = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertNil(unavailable.currentPowerMicrowatts)
        XCTAssertNil(unavailable.rankingScore)
    }

    func testDuplicateGenerationInOnePublicationMarksSecondEntryUnavailable() async throws {
        let clock = EnergyImpactTestClock()
        let model = EnergyImpactModel(
            provider: EnergyImpactProviderStub(
                responses: [
                    [],
                    [
                        entry(pid: 101, power: 10, startTime: 10),
                        entry(pid: 101, power: 20, startTime: 10),
                    ],
                ]
            ),
            clock: clock,
            sleep: { _ in clock.advance(seconds: 3) }
        )

        await model.refresh()

        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(model.entries.filter { $0.status == .stable }.count, 1)
        let unavailable = try XCTUnwrap(model.entries.first { $0.status == .unavailable })
        XCTAssertNil(unavailable.currentPowerMicrowatts)
        XCTAssertNil(unavailable.rankingScore)
    }

    func testInvalidStaleNumericsAreStrippedWithoutChangingStaleStatus() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [entry(power: 0)],
                [entry(power: .nan, status: .stale)]
            ]
        )
        let model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in clock.advance(seconds: 3) }
        )

        await model.refresh()

        let stale = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(stale.status, .stale)
        XCTAssertNil(stale.currentPowerMicrowatts)
        XCTAssertNil(stale.sustainedPowerMicrowatts)
        XCTAssertNil(stale.rankingScore)
    }

    func testNonfiniteClockPreservesCollectingStaleAndUnavailableStates() async throws {
        let clock = EnergyImpactTestClock(value: .nan)
        let provider = EnergyImpactProviderStub(
            responses: [
                [],
                [
                    entry(pid: 1, power: nil, status: .collecting),
                    entry(pid: 2, power: 100, status: .stale),
                    entry(pid: 3, power: nil, status: .unavailable),
                    entry(pid: 4, power: 100, status: .stable),
                    entry(pid: 5, power: 100, status: .partial),
                ],
            ]
        )
        let model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in }
        )

        await model.refresh()

        let byPID = Dictionary(uniqueKeysWithValues: model.entries.map {
            ($0.processIdentifier, $0)
        })
        XCTAssertEqual(try XCTUnwrap(byPID[1]).status, .collecting)
        XCTAssertEqual(try XCTUnwrap(byPID[2]).status, .stale)
        XCTAssertEqual(try XCTUnwrap(byPID[2]).currentPowerMicrowatts, 100)
        XCTAssertEqual(try XCTUnwrap(byPID[3]).status, .unavailable)
        XCTAssertEqual(try XCTUnwrap(byPID[4]).status, .unavailable)
        XCTAssertNil(try XCTUnwrap(byPID[4]).currentPowerMicrowatts)
        XCTAssertEqual(try XCTUnwrap(byPID[5]).status, .unavailable)
        XCTAssertNil(try XCTUnwrap(byPID[5]).currentPowerMicrowatts)
    }

    func testRecoveryAfterStaleSeriesBeyondMaximumGapStartsFreshEMA() async throws {
        let clock = EnergyImpactTestClock()
        let provider = EnergyImpactProviderStub(
            responses: [
                [],
                [entry(power: 100)],
                [entry(power: 100, status: .stale)],
                [entry(power: 100, status: .stale)],
                [entry(power: 100, status: .stale)],
                [entry(power: 0)],
            ]
        )
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            clock: clock,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount < 6 else { throw CancellationError() }
                clock.advance(seconds: 3)
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(try XCTUnwrap(model.entries.first?.status), .stable)
        XCTAssertEqual(try XCTUnwrap(model.entries.first?.currentPowerMicrowatts), 0)
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
    private var value: TimeInterval

    init(value: TimeInterval = 0) {
        self.value = value
    }

    func nowSeconds() -> TimeInterval {
        value
    }

    func advance(seconds: TimeInterval) {
        value += seconds
    }
}
