import Combine
import Foundation
import MacActivityCore

@MainActor
protocol EnergyImpactProviding: AnyObject {
    func beginSession() async -> EnergyImpactSamplingLease?

    func observe(
        lease: EnergyImpactSamplingLease,
        limit: Int,
        scope: EnergyImpactAppScope
    ) async -> [EnergyImpactEntry]?

    func endSession(_ lease: EnergyImpactSamplingLease) async
}

extension EnergyImpactService: EnergyImpactProviding {}

@MainActor
final class EnergyImpactModel: ObservableObject {
    @Published private(set) var entries: [EnergyImpactEntry] = []
    @Published private(set) var isRefreshing = false

    private let provider: any EnergyImpactProviding
    private let limit: Int
    private let initialWindowNanoseconds: UInt64
    private let sleep: (UInt64) async throws -> Void
    private var activeRunID: UUID?

    init(
        provider: any EnergyImpactProviding = EnergyImpactService(),
        limit: Int = 20,
        initialWindowNanoseconds: UInt64 = 3_000_000_000,
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.provider = provider
        self.limit = limit
        self.initialWindowNanoseconds = initialWindowNanoseconds
        self.sleep = sleep
    }

    func refresh() async {
        let runID = beginRun()
        guard canContinue(runID) else {
            finishIfCurrent(runID)
            return
        }
        await performRun(runID, refreshIntervalNanoseconds: nil)
    }

    func refreshWhileVisible(
        refreshIntervalNanoseconds: UInt64 = 3_000_000_000
    ) async {
        let runID = beginRun()
        guard canContinue(runID) else {
            finishIfCurrent(runID)
            return
        }
        await performRun(
            runID,
            refreshIntervalNanoseconds: refreshIntervalNanoseconds
        )
    }

    private func beginRun() -> UUID {
        let runID = UUID()
        activeRunID = runID
        isRefreshing = true
        return runID
    }

    private func performRun(
        _ runID: UUID,
        refreshIntervalNanoseconds: UInt64?
    ) async {
        let lease = await provider.beginSession()
        guard canContinue(runID), let lease else {
            if let lease {
                await provider.endSession(lease)
            }
            finishIfCurrent(runID)
            return
        }

        var remainsActive = await observeAndPublish(
            lease: lease,
            runID: runID
        )
        if remainsActive {
            remainsActive = await sleepAndObserve(
                initialWindowNanoseconds,
                lease: lease,
                runID: runID
            )
        }

        if let refreshIntervalNanoseconds {
            while remainsActive {
                remainsActive = await sleepAndObserve(
                    refreshIntervalNanoseconds,
                    lease: lease,
                    runID: runID
                )
            }
        }

        await provider.endSession(lease)
        finishIfCurrent(runID)
    }

    private func sleepAndObserve(
        _ duration: UInt64,
        lease: EnergyImpactSamplingLease,
        runID: UUID
    ) async -> Bool {
        do {
            try await sleep(duration)
        } catch {
            return false
        }
        guard canContinue(runID) else { return false }
        return await observeAndPublish(lease: lease, runID: runID)
    }

    private func observeAndPublish(
        lease: EnergyImpactSamplingLease,
        runID: UUID
    ) async -> Bool {
        let observed = await provider.observe(
            lease: lease,
            limit: limit,
            scope: .regularOnly
        )
        guard canContinue(runID), let observed else { return false }
        guard canContinue(runID) else { return false }
        entries = observed
        return true
    }

    private func canContinue(_ runID: UUID) -> Bool {
        Task.isCancelled == false && activeRunID == runID
    }

    private func finishIfCurrent(_ runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        isRefreshing = false
    }
}
