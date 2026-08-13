import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testSixtySecondVisibleLifecycleMakesTwentyOneCompleteObservations() async {
        let provider = ControlledEnergyImpactProvider()
        var now: UInt64 = 0
        var requestedSleeps = [UInt64]()
        let interval: UInt64 = 3_000_000_000
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: interval,
            nowNanoseconds: { now },
            sleep: { duration in
                requestedSleeps.append(duration)
                guard requestedSleeps.count <= 20 else {
                    throw CancellationError()
                }
                now += duration
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(provider.observeCount, 21)
        XCTAssertEqual(requestedSleeps.count, 21)
        XCTAssertEqual(
            Array(requestedSleeps.prefix(20)),
            Array(repeating: interval, count: 20)
        )
        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(provider.endCount, 1)
        XCTAssertEqual(provider.endedLeases, provider.returnedLeases)
        XCTAssertEqual(model.entries.first?.name, "Run 1 Observation 21")
        XCTAssertFalse(model.isRefreshing)
    }

    func testAlreadyCancelledRunPerformsNoBeginObserveOrEnd() async {
        let provider = ControlledEnergyImpactProvider()
        let model = EnergyImpactModel(provider: provider)

        let run = Task { await model.refreshWhileVisible() }
        run.cancel()
        await run.value

        XCTAssertEqual(provider.beginCount, 0)
        XCTAssertEqual(provider.observeCount, 0)
        XCTAssertEqual(provider.endCount, 0)
        XCTAssertFalse(model.isRefreshing)
    }

    func testCancellationAfterObserveBeforePublicationDoesNotPublish() async {
        let provider = PublicationBarrierProvider()
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()
        XCTAssertEqual(model.entries.first?.name, "Prior")

        let run = Task { await model.refreshWhileVisible() }
        await provider.waitUntilFinalReturnBarrier()
        run.cancel()
        provider.releaseFinalReturnBarrier()
        await run.value

        XCTAssertEqual(provider.completedObservationCount, 2)
        XCTAssertEqual(model.entries.first?.name, "Prior")
        XCTAssertEqual(provider.endCount, 2)
        XCTAssertEqual(provider.endedLeases, provider.returnedLeases)
        XCTAssertFalse(model.isRefreshing)
    }

    func testNewVisibleRunHidesCoverageUntilItAcceptsAnObservation() async {
        let provider = PublicationBarrierProvider()
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()
        XCTAssertNotNil(EnergyImpactView.coverageText(model: model))

        let run = Task { await model.refreshWhileVisible() }
        await provider.waitUntilFinalReturnBarrier()

        XCTAssertNil(EnergyImpactView.coverageText(model: model))

        run.cancel()
        provider.releaseFinalReturnBarrier()
        await run.value
    }

    func testEveryReturnedLeaseEndsOnceWhenSleepThrows() async {
        let provider = ControlledEnergyImpactProvider()
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 3,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(provider.observeCount, 1)
        XCTAssertEqual(provider.endCount, 1)
        XCTAssertEqual(provider.endedLeases, provider.returnedLeases)
        XCTAssertFalse(model.isRefreshing)
    }

    func testEveryReturnedLeaseEndsOnceWhenObserveReturnsNil() async {
        let provider = ControlledEnergyImpactProvider(
            nilObservationCounts: [1]
        )
        let model = EnergyImpactModel(provider: provider)

        await model.refreshWhileVisible()

        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(provider.observeCount, 1)
        XCTAssertEqual(provider.endCount, 1)
        XCTAssertEqual(provider.endedLeases, provider.returnedLeases)
        XCTAssertFalse(model.isRefreshing)
    }

    func testSlowObservationSkipsMissedDeadlinesWithoutBurst() async {
        var now: UInt64 = 0
        var requestedSleeps = [UInt64]()
        let provider = ControlledEnergyImpactProvider(
            onObservation: { observationCount in
                if observationCount == 1 { now = 7 }
            }
        )
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 3,
            nowNanoseconds: { now },
            sleep: { duration in
                requestedSleeps.append(duration)
                throw CancellationError()
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(requestedSleeps, [2])
        XCTAssertEqual(provider.observeCount, 1)
        XCTAssertEqual(provider.endCount, 1)
    }

    func testConcurrentVisibleRunsEndEachReturnedLeaseExactlyOnce() async {
        let provider = ControlledEnergyImpactProvider()
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 60_000_000_000
        )

        let runA = Task { await model.refreshWhileVisible() }
        while provider.observeCount < 1 { await Task.yield() }
        let runB = Task { await model.refreshWhileVisible() }
        while provider.observeCount < 2 { await Task.yield() }

        runA.cancel()
        runB.cancel()
        await runA.value
        await runB.value
        XCTAssertEqual(provider.beginCount, 2)
        XCTAssertEqual(provider.endCount, 2)
        XCTAssertEqual(Set(provider.endedLeases), Set(provider.returnedLeases))
    }

    func testReplacementCannotPublishOlderCompletedObservation() async {
        let provider = ReplacementRunProvider(blockOldSecondObservation: true)
        let sleep = SequencedSleepController()
        let model = EnergyImpactModel(
            provider: provider,
            sleep: { try await sleep.call($0) }
        )

        let runA = Task { await model.refreshWhileVisible() }
        await provider.waitUntilOldSecondObservationStarts()
        let runB = Task { await model.refreshWhileVisible() }
        await sleep.waitUntilSecondSleepStarts()

        XCTAssertEqual(model.entries.first?.name, "Run B")
        provider.releaseOldSecondObservation()
        await runA.value

        XCTAssertEqual(model.entries.first?.name, "Run B")
        await sleep.failSecondSleep()
        await runB.value
    }

    func testOldExitCannotClearReplacementRefreshingState() async {
        let provider = ReplacementRunProvider(
            blockOldEnd: true,
            blockNewFirstObservation: true
        )
        let sleep = SequencedSleepController(failsFirstSleep: true)
        let model = EnergyImpactModel(
            provider: provider,
            sleep: { try await sleep.call($0) }
        )

        let runA = Task { await model.refreshWhileVisible() }
        await provider.waitUntilOldEndStarts()
        let runB = Task { await model.refreshWhileVisible() }
        await provider.waitUntilNewFirstObservationStarts()

        XCTAssertTrue(model.isRefreshing)
        provider.releaseOldEnd()
        await runA.value

        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(provider.endedLeases.map(\.requestGeneration), [1])
        provider.releaseNewFirstObservation()
        await sleep.waitUntilSecondSleepStarts()
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
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            limit: 2,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in
                sleepCount += 1
                guard sleepCount == 1 else { throw CancellationError() }
            }
        )

        await model.refreshWhileVisible()

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
    private let nilObservationCounts: Set<Int>
    private let onObservation: ((Int) -> Void)?
    private(set) var beginCount = 0
    private(set) var observeCount = 0
    private(set) var endCount = 0
    private(set) var returnedLeases: [EnergyImpactSamplingLease] = []
    private(set) var observedLeases: [EnergyImpactSamplingLease] = []
    private(set) var endedLeases: [EnergyImpactSamplingLease] = []
    private(set) var requestedLimits: [Int] = []
    private(set) var requestedScopes: [EnergyImpactAppScope] = []
    private var observationCountsByLease: [UInt64: Int] = [:]

    init(
        responses: [[EnergyImpactEntry]] = [],
        nilObservationCounts: Set<Int> = [],
        onObservation: ((Int) -> Void)? = nil
    ) {
        self.responses = responses
        self.nilObservationCounts = nilObservationCounts
        self.onObservation = onObservation
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
        observeCount += 1
        observationCountsByLease[lease.requestGeneration, default: 0] += 1
        let leaseObservationCount = observationCountsByLease[lease.requestGeneration, default: 0]
        onObservation?(observeCount)
        observedLeases.append(lease)
        requestedLimits.append(limit)
        requestedScopes.append(scope)
        guard nilObservationCounts.contains(observeCount) == false else {
            return nil
        }
        if responses.isEmpty == false { return responses.removeFirst() }
        return [entry(
            pid: pid_t(lease.requestGeneration),
            name: "Run \(lease.requestGeneration) Observation \(leaseObservationCount)",
            power: Double(leaseObservationCount)
        )]
    }

    func endSession(_ lease: EnergyImpactSamplingLease) async {
        endCount += 1
        endedLeases.append(lease)
    }
}

@MainActor
private final class PublicationBarrierProvider: EnergyImpactProviding {
    private var finalReturnContinuation: CheckedContinuation<Void, Never>?
    private(set) var completedObservationCount = 0
    private(set) var endCount = 0
    private(set) var returnedLeases: [EnergyImpactSamplingLease] = []
    private(set) var endedLeases: [EnergyImpactSamplingLease] = []

    func beginSession() async -> EnergyImpactSamplingLease? {
        let lease = EnergyImpactSamplingLease(
            requestGeneration: UInt64(returnedLeases.count + 1)
        )
        returnedLeases.append(lease)
        return lease
    }

    func observe(
        lease: EnergyImpactSamplingLease,
        limit: Int,
        scope: EnergyImpactAppScope
    ) async -> [EnergyImpactEntry]? {
        completedObservationCount += 1
        if lease.requestGeneration == 2 {
            await withCheckedContinuation { finalReturnContinuation = $0 }
        }
        return [entry(
            name: lease.requestGeneration == 1 ? "Prior" : "Cancelled",
            power: Double(lease.requestGeneration)
        )]
    }

    func endSession(_ lease: EnergyImpactSamplingLease) async {
        endCount += 1
        endedLeases.append(lease)
    }

    func waitUntilFinalReturnBarrier() async {
        while finalReturnContinuation == nil { await Task.yield() }
    }

    func releaseFinalReturnBarrier() {
        finalReturnContinuation?.resume()
        finalReturnContinuation = nil
    }
}

@MainActor
private final class ReplacementRunProvider: EnergyImpactProviding {
    private let blockOldSecondObservation: Bool
    private let blockOldEnd: Bool
    private let blockNewFirstObservation: Bool
    private var beginCount = 0
    private var observationCounts: [UInt64: Int] = [:]
    private var oldSecondStarted = false
    private var oldSecondContinuation: CheckedContinuation<Void, Never>?
    private var oldEndStarted = false
    private var oldEndContinuation: CheckedContinuation<Void, Never>?
    private var newFirstObservationStarted = false
    private var newFirstObservationContinuation: CheckedContinuation<Void, Never>?
    private(set) var endedLeases: [EnergyImpactSamplingLease] = []

    init(
        blockOldSecondObservation: Bool = false,
        blockOldEnd: Bool = false,
        blockNewFirstObservation: Bool = false
    ) {
        self.blockOldSecondObservation = blockOldSecondObservation
        self.blockOldEnd = blockOldEnd
        self.blockNewFirstObservation = blockNewFirstObservation
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
        if generation == 2, count == 1, blockNewFirstObservation {
            newFirstObservationStarted = true
            await withCheckedContinuation { newFirstObservationContinuation = $0 }
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

    func waitUntilNewFirstObservationStarts() async {
        while newFirstObservationStarted == false { await Task.yield() }
    }

    func releaseNewFirstObservation() {
        newFirstObservationContinuation?.resume()
        newFirstObservationContinuation = nil
    }
}

private actor SequencedSleepController {
    private let failsFirstSleep: Bool
    private var callCount = 0
    private var secondSleepStarted = false
    private var secondSleepContinuation: CheckedContinuation<Void, Error>?

    init(failsFirstSleep: Bool = false) {
        self.failsFirstSleep = failsFirstSleep
    }

    func call(_ duration: UInt64) async throws {
        callCount += 1
        if callCount == 1, failsFirstSleep {
            throw CancellationError()
        }
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
