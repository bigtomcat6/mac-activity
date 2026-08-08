import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testRefreshUsesOneLeaseForImmediateAndSecondObservation() async throws {
        let provider = ControlledEnergyImpactProvider(responses: [
            [entry(power: nil, status: .collecting)],
            [entry(power: 1)],
        ])
        var requestedSleeps: [UInt64] = []
        let model = EnergyImpactModel(
            provider: provider,
            initialWindowNanoseconds: 3_000_000_000,
            sleep: { requestedSleeps.append($0) }
        )

        await model.refresh()

        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(provider.observedLeases, provider.returnedLeases + provider.returnedLeases)
        XCTAssertEqual(provider.requestedLimits, [20, 20])
        XCTAssertEqual(provider.requestedScopes, [.regularOnly, .regularOnly])
        XCTAssertEqual(requestedSleeps, [3_000_000_000])
        XCTAssertEqual(try XCTUnwrap(model.entries.first?.currentPowerMicrowatts), 1)
        XCTAssertEqual(provider.endCount, 1)
        XCTAssertFalse(model.isRefreshing)
    }

    func testInitialCancellationEndsEveryLeaseThatSuccessfullyBegan() async {
        let provider = ControlledEnergyImpactProvider(responses: [[]])
        let model = EnergyImpactModel(
            provider: provider,
            initialWindowNanoseconds: 1,
            sleep: { _ in throw CancellationError() }
        )

        await model.refresh()

        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(provider.endCount, 1)
        XCTAssertEqual(provider.endedLeases, provider.returnedLeases)
        XCTAssertFalse(model.isRefreshing)
    }

    func testRefreshWhileVisibleUsesOneLeaseAndAwaitsObservationsSequentially() async {
        let provider = ControlledEnergyImpactProvider(
            responses: [[], [], []],
            cancelTaskAfterObservationCount: 3
        )
        let model = EnergyImpactModel(
            provider: provider,
            initialWindowNanoseconds: 1,
            sleep: { _ in await Task.yield() }
        )

        await model.refreshWhileVisible(refreshIntervalNanoseconds: 3)

        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(provider.observeCount, 3)
        XCTAssertEqual(Set(provider.observedLeases).count, 1)
        XCTAssertEqual(provider.maximumConcurrentObservations, 1)
        XCTAssertEqual(provider.endCount, 1)
        XCTAssertFalse(model.isRefreshing)
    }

    func testReplacementCannotPublishOlderCompletedObservation() async {
        let provider = ReplacementRunProvider(blockOldSecondObservation: true)
        let sleep = SequencedSleepController()
        let model = EnergyImpactModel(
            provider: provider,
            sleep: { try await sleep.call($0) }
        )

        let runA = Task { await model.refresh() }
        await provider.waitUntilOldSecondObservationStarts()
        let runB = Task { await model.refresh() }
        await sleep.waitUntilSecondSleepStarts()

        XCTAssertEqual(model.entries.first?.name, "Run B")
        provider.releaseOldSecondObservation()
        await runA.value

        XCTAssertEqual(model.entries.first?.name, "Run B")
        await sleep.failSecondSleep()
        await runB.value
    }

    func testOldExitCannotClearReplacementRefreshingState() async {
        let provider = ReplacementRunProvider(blockOldEnd: true)
        let sleep = SequencedSleepController()
        let model = EnergyImpactModel(
            provider: provider,
            sleep: { try await sleep.call($0) }
        )

        let runA = Task { await model.refresh() }
        await provider.waitUntilOldEndStarts()
        let runB = Task { await model.refresh() }
        await sleep.waitUntilSecondSleepStarts()

        XCTAssertTrue(model.isRefreshing)
        provider.releaseOldEnd()
        await runA.value

        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(provider.endedLeases.map(\.requestGeneration), [1])
        await sleep.failSecondSleep()
        await runB.value
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(provider.endedLeases.map(\.requestGeneration), [1, 2])
    }

    func testReturnedRowsAreAssignedUnchangedWithConfiguredLimit() async {
        let expected = [
            entry(pid: 303, name: "Third", power: 3),
            entry(pid: 101, name: "First", power: 1),
        ]
        let provider = ControlledEnergyImpactProvider(responses: [[], expected])
        let model = EnergyImpactModel(
            provider: provider,
            limit: 2,
            initialWindowNanoseconds: 0,
            sleep: { _ in }
        )

        await model.refresh()

        XCTAssertEqual(model.entries, expected)
        XCTAssertEqual(provider.requestedLimits, [2, 2])
    }
}

private func entry(
    pid: pid_t = 101,
    name: String? = nil,
    power: Double?,
    startTime: UInt64? = 1,
    status: EnergyImpactStatus = .stable
) -> EnergyImpactEntry {
    EnergyImpactEntry(
        identity: EnergyImpactAppIdentity(
            rootProcessIdentifier: pid,
            rootProcessStartAbsoluteTime: startTime
        ),
        name: name ?? "App \(pid)",
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
private final class ControlledEnergyImpactProvider: EnergyImpactProviding {
    private var responses: [[EnergyImpactEntry]]
    private let cancelTaskAfterObservationCount: Int?
    private(set) var beginCount = 0
    private(set) var observeCount = 0
    private(set) var endCount = 0
    private(set) var returnedLeases: [EnergyImpactSamplingLease] = []
    private(set) var observedLeases: [EnergyImpactSamplingLease] = []
    private(set) var endedLeases: [EnergyImpactSamplingLease] = []
    private(set) var requestedLimits: [Int] = []
    private(set) var requestedScopes: [EnergyImpactAppScope] = []
    private var concurrentObservations = 0
    private(set) var maximumConcurrentObservations = 0

    init(
        responses: [[EnergyImpactEntry]],
        cancelTaskAfterObservationCount: Int? = nil
    ) {
        self.responses = responses
        self.cancelTaskAfterObservationCount = cancelTaskAfterObservationCount
    }

    func beginSession() async -> EnergyImpactSamplingLease? {
        beginCount += 1
        let lease = EnergyImpactSamplingLease(requestGeneration: UInt64(beginCount))
        returnedLeases.append(lease)
        return lease
    }

    func observe(
        lease: EnergyImpactSamplingLease,
        limit: Int,
        scope: EnergyImpactAppScope
    ) async -> [EnergyImpactEntry]? {
        concurrentObservations += 1
        maximumConcurrentObservations = max(
            maximumConcurrentObservations,
            concurrentObservations
        )
        await Task.yield()
        concurrentObservations -= 1
        observeCount += 1
        observedLeases.append(lease)
        requestedLimits.append(limit)
        requestedScopes.append(scope)
        if observeCount == cancelTaskAfterObservationCount {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        guard responses.isEmpty == false else { return [] }
        return responses.removeFirst()
    }

    func endSession(_ lease: EnergyImpactSamplingLease) async {
        endCount += 1
        endedLeases.append(lease)
    }
}

@MainActor
private final class ReplacementRunProvider: EnergyImpactProviding {
    private let blockOldSecondObservation: Bool
    private let blockOldEnd: Bool
    private var beginCount = 0
    private var observationCounts: [UInt64: Int] = [:]
    private var oldSecondStarted = false
    private var oldSecondContinuation: CheckedContinuation<Void, Never>?
    private var oldEndStarted = false
    private var oldEndContinuation: CheckedContinuation<Void, Never>?
    private(set) var endedLeases: [EnergyImpactSamplingLease] = []

    init(
        blockOldSecondObservation: Bool = false,
        blockOldEnd: Bool = false
    ) {
        self.blockOldSecondObservation = blockOldSecondObservation
        self.blockOldEnd = blockOldEnd
    }

    func beginSession() async -> EnergyImpactSamplingLease? {
        beginCount += 1
        return EnergyImpactSamplingLease(requestGeneration: UInt64(beginCount))
    }

    func observe(
        lease: EnergyImpactSamplingLease,
        limit: Int,
        scope: EnergyImpactAppScope
    ) async -> [EnergyImpactEntry]? {
        let generation = lease.requestGeneration
        observationCounts[generation, default: 0] += 1
        let count = observationCounts[generation, default: 0]
        if generation == 1, count == 2, blockOldSecondObservation {
            oldSecondStarted = true
            await withCheckedContinuation { oldSecondContinuation = $0 }
        }
        let name = generation == 1 && count == 2 ? "Old A" : "Run \(generation == 1 ? "A" : "B")"
        return [entry(pid: pid_t(generation), name: name, power: Double(generation))]
    }

    func endSession(_ lease: EnergyImpactSamplingLease) async {
        if lease.requestGeneration == 1, blockOldEnd {
            oldEndStarted = true
            await withCheckedContinuation { oldEndContinuation = $0 }
        }
        endedLeases.append(lease)
    }

    func waitUntilOldSecondObservationStarts() async {
        while oldSecondStarted == false { await Task.yield() }
    }

    func releaseOldSecondObservation() {
        oldSecondContinuation?.resume()
        oldSecondContinuation = nil
    }

    func waitUntilOldEndStarts() async {
        while oldEndStarted == false { await Task.yield() }
    }

    func releaseOldEnd() {
        oldEndContinuation?.resume()
        oldEndContinuation = nil
    }
}

private actor SequencedSleepController {
    private var callCount = 0
    private var secondSleepStarted = false
    private var secondSleepContinuation: CheckedContinuation<Void, Error>?

    func call(_ duration: UInt64) async throws {
        callCount += 1
        if callCount == 1 { return }
        secondSleepStarted = true
        try await withCheckedThrowingContinuation { continuation in
            secondSleepContinuation = continuation
        }
    }

    func waitUntilSecondSleepStarts() async {
        while secondSleepStarted == false { await Task.yield() }
    }

    func failSecondSleep() {
        secondSleepContinuation?.resume(throwing: CancellationError())
        secondSleepContinuation = nil
    }
}
