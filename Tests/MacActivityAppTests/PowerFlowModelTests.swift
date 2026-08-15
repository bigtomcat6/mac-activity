import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PowerFlowModelTests: XCTestCase {
    func testVisibleRunPublishesImmediateSnapshotThenUsesThreeSecondCadence() async {
        let provider = SequencePowerFlowProvider(responses: [
            inputSnapshot(watts: 12),
            inputSnapshot(watts: 18),
        ])
        var now: UInt64 = 0
        var sleeps = [UInt64]()
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 3_000_000_000,
            nowNanoseconds: { now },
            sleep: { duration in
                sleeps.append(duration)
                now += duration
                if sleeps.count == 2 { throw CancellationError() }
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(model.snapshot.inputEndpoints.first?.measurement, .watts(18))
        XCTAssertEqual(sleeps, [3_000_000_000, 3_000_000_000])
        XCTAssertEqual(provider.snapshotCount, 2)
        XCTAssertFalse(model.isRefreshing)
    }

    func testCancelledRunDoesNotBeginAPostCancellationRead() async {
        let provider = SequencePowerFlowProvider(responses: [inputSnapshot(watts: 12)])
        let model = PowerFlowModel(provider: provider)
        let run = Task { await model.refreshWhileVisible() }

        run.cancel()
        await run.value

        XCTAssertEqual(provider.snapshotCount, 0)
        XCTAssertFalse(model.isRefreshing)
    }

    func testNewRunClearsPreviousMeasuredWattsUntilItsFirstSnapshot() async {
        let provider = SecondReadBarrierPowerFlowProvider()
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()
        XCTAssertEqual(model.snapshot.inputEndpoints.first?.measurement, .watts(24))

        let replacement = Task { await model.refreshWhileVisible() }
        await provider.waitUntilSecondReadStarts()
        XCTAssertEqual(model.snapshot, .empty)

        provider.releaseSecondRead()
        await replacement.value
        XCTAssertEqual(model.snapshot.inputEndpoints.first?.measurement, .watts(18))
    }

    func testDelayedOlderRunCannotOverwriteNewerSnapshot() async {
        let provider = FirstReadBarrierPowerFlowProvider()
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        let olderRun = Task { await model.refreshWhileVisible() }
        await provider.waitUntilFirstReadStarts()

        let newerRun = Task { await model.refreshWhileVisible() }
        await newerRun.value
        XCTAssertEqual(model.snapshot.inputEndpoints.first?.measurement, .watts(18))

        provider.releaseFirstRead()
        await olderRun.value
        XCTAssertEqual(model.snapshot.inputEndpoints.first?.measurement, .watts(18))
    }

    func testRefreshStopsAfterSleepCancellation() async {
        let provider = SequencePowerFlowProvider(responses: [inputSnapshot(watts: 12)])
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(provider.snapshotCount, 1)
        XCTAssertFalse(model.isRefreshing)
    }
}

@MainActor
private final class SequencePowerFlowProvider: PowerFlowProviding {
    private var responses: [PowerFlowSnapshot]
    private(set) var snapshotCount = 0

    init(responses: [PowerFlowSnapshot]) {
        self.responses = responses
    }

    func snapshot() async -> PowerFlowSnapshot {
        snapshotCount += 1
        return responses.removeFirst()
    }
}

@MainActor
private final class SecondReadBarrierPowerFlowProvider: PowerFlowProviding {
    private var secondReadContinuation: CheckedContinuation<Void, Never>?
    private var secondReadStarted = false
    private var count = 0

    func snapshot() async -> PowerFlowSnapshot {
        count += 1
        if count == 1 { return inputSnapshot(watts: 24) }
        secondReadStarted = true
        await withCheckedContinuation { secondReadContinuation = $0 }
        return inputSnapshot(watts: 18)
    }

    func waitUntilSecondReadStarts() async {
        while secondReadStarted == false { await Task.yield() }
    }

    func releaseSecondRead() {
        secondReadContinuation?.resume()
        secondReadContinuation = nil
    }
}

@MainActor
private final class FirstReadBarrierPowerFlowProvider: PowerFlowProviding {
    private var firstReadContinuation: CheckedContinuation<Void, Never>?
    private var firstReadStarted = false
    private var count = 0

    func snapshot() async -> PowerFlowSnapshot {
        count += 1
        if count == 1 {
            firstReadStarted = true
            await withCheckedContinuation { firstReadContinuation = $0 }
            return inputSnapshot(watts: 24)
        }
        return inputSnapshot(watts: 18)
    }

    func waitUntilFirstReadStarts() async {
        while firstReadStarted == false { await Task.yield() }
    }

    func releaseFirstRead() {
        firstReadContinuation?.resume()
        firstReadContinuation = nil
    }
}

private func inputSnapshot(watts: Double) -> PowerFlowSnapshot {
    PowerFlowSnapshot(endpoints: [
        PowerFlowEndpoint(id: "battery", type: .battery, direction: .input, measurement: .watts(watts)),
        PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .unavailable),
    ])
}
