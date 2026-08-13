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
    @Published private(set) var hasReceivedObservation = false
    @Published private(set) var isRefreshing = false

    private let provider: any EnergyImpactProviding
    private let limit: Int
    private let observationIntervalNanoseconds: UInt64
    private let nowNanoseconds: () -> UInt64
    private let sleep: (UInt64) async throws -> Void
    private var activeRunID: UUID?

    init(
        provider: any EnergyImpactProviding = EnergyImpactService(),
        limit: Int = 20,
        observationIntervalNanoseconds: UInt64 = 3_000_000_000,
        nowNanoseconds: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.provider = provider
        self.limit = limit
        self.observationIntervalNanoseconds = observationIntervalNanoseconds
        self.nowNanoseconds = nowNanoseconds
        self.sleep = sleep
    }

    func refreshWhileVisible(
        scope: EnergyImpactAppScope = .regularOnly
    ) async {
        let runID = UUID()
        activeRunID = runID
        isRefreshing = true

        guard Task.isCancelled == false else {
            finishRun(runID)
            return
        }
        guard let lease = await provider.beginSession() else {
            finishRun(runID)
            return
        }

        var deadline = nowNanoseconds()
        do {
            while Task.isCancelled == false, activeRunID == runID {
                let now = nowNanoseconds()
                if deadline > now {
                    try await sleep(deadline - now)
                }
                guard Task.isCancelled == false,
                      activeRunID == runID else {
                    break
                }
                guard let observed = await provider.observe(
                    lease: lease,
                    limit: limit,
                    scope: scope
                ) else {
                    break
                }
                guard Task.isCancelled == false,
                      activeRunID == runID else {
                    break
                }

                entries = observed
                hasReceivedObservation = true
                isRefreshing = false
                deadline = Self.firstFutureDeadline(
                    after: deadline,
                    now: nowNanoseconds(),
                    interval: observationIntervalNanoseconds
                )
            }
        } catch is CancellationError {
            // Normal hidden-page exit; cleanup below still runs.
        } catch {
            // Preserve the last honest rows; a future visible run retries.
        }

        await provider.endSession(lease)
        finishRun(runID)
    }

    private static func firstFutureDeadline(
        after previousDeadline: UInt64,
        now: UInt64,
        interval rawInterval: UInt64
    ) -> UInt64 {
        let interval = max(1, rawInterval)
        let (first, firstOverflow) =
            previousDeadline.addingReportingOverflow(interval)
        guard firstOverflow == false else { return .max }
        guard first <= now else { return first }

        let missed = (now - first) / interval + 1
        let (jump, jumpOverflow) =
            interval.multipliedReportingOverflow(by: missed)
        guard jumpOverflow == false else { return .max }
        let (advanced, advancedOverflow) =
            first.addingReportingOverflow(jump)
        return advancedOverflow ? .max : advanced
    }

    private func finishRun(_ runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        isRefreshing = false
    }
}
