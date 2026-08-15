import Combine
import Foundation
import MacActivityCore

@MainActor
protocol PowerFlowProviding: AnyObject {
    func snapshot() async -> PowerFlowSnapshot
}

extension PowerFlowService: PowerFlowProviding {}

@MainActor
final class PowerFlowModel: ObservableObject {
    @Published private(set) var snapshot = PowerFlowSnapshot.empty
    @Published private(set) var isRefreshing = false

    private let provider: any PowerFlowProviding
    private let observationIntervalNanoseconds: UInt64
    private let nowNanoseconds: () -> UInt64
    private let sleep: (UInt64) async throws -> Void
    private var activeRunID: UUID?

    init(
        provider: any PowerFlowProviding = PowerFlowService(),
        observationIntervalNanoseconds: UInt64 = 3_000_000_000,
        nowNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.provider = provider
        self.observationIntervalNanoseconds = observationIntervalNanoseconds
        self.nowNanoseconds = nowNanoseconds
        self.sleep = sleep
    }

    func refreshWhileVisible() async {
        let runID = UUID()
        activeRunID = runID
        snapshot = .empty
        isRefreshing = true

        guard Task.isCancelled == false else {
            finishRun(runID)
            return
        }

        var deadline = nowNanoseconds()
        do {
            while Task.isCancelled == false, activeRunID == runID {
                let observed = await provider.snapshot()
                guard Task.isCancelled == false, activeRunID == runID else { break }

                snapshot = observed
                isRefreshing = false
                deadline = Self.firstFutureDeadline(
                    after: deadline,
                    now: nowNanoseconds(),
                    interval: observationIntervalNanoseconds
                )

                let now = nowNanoseconds()
                if deadline > now {
                    try await sleep(deadline - now)
                }
            }
        } catch is CancellationError {
            // The view left the hierarchy or the test ended its visible run.
        } catch {
            // A subsequent visible run retries with a fresh snapshot.
        }

        finishRun(runID)
    }

    private static func firstFutureDeadline(
        after previousDeadline: UInt64,
        now: UInt64,
        interval rawInterval: UInt64
    ) -> UInt64 {
        let interval = max(1, rawInterval)
        let (first, firstOverflow) = previousDeadline.addingReportingOverflow(interval)
        guard firstOverflow == false else { return .max }
        guard first > now else {
            let missed = (now - first) / interval + 1
            let (jump, jumpOverflow) = interval.multipliedReportingOverflow(by: missed)
            guard jumpOverflow == false else { return .max }
            let (advanced, advancedOverflow) = first.addingReportingOverflow(jump)
            return advancedOverflow ? .max : advanced
        }
        return first
    }

    private func finishRun(_ runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        isRefreshing = false
    }
}
