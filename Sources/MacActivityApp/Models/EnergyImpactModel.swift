import Combine
import Foundation
import MacActivityCore

@MainActor
protocol EnergyImpactProviding: AnyObject {
    func topApps(limit: Int) -> [EnergyImpactEntry]
}

extension EnergyImpactService: EnergyImpactProviding {}

@MainActor
final class EnergyImpactModel: ObservableObject {
    @Published private(set) var entries: [EnergyImpactEntry] = []
    @Published private(set) var isRefreshing = false

    private let provider: any EnergyImpactProviding
    private let limit: Int
    private let samplingDelayNanoseconds: UInt64
    private let sleep: (UInt64) async throws -> Void

    init(
        provider: any EnergyImpactProviding = EnergyImpactService(),
        limit: Int = 20,
        samplingDelayNanoseconds: UInt64 = 250_000_000,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.provider = provider
        self.limit = limit
        self.samplingDelayNanoseconds = samplingDelayNanoseconds
        self.sleep = sleep
    }

    func refresh() async {
        isRefreshing = true
        _ = provider.topApps(limit: limit)
        do {
            try await sleep(samplingDelayNanoseconds)
        } catch {
            isRefreshing = false
            return
        }
        guard Task.isCancelled == false else {
            isRefreshing = false
            return
        }
        entries = provider.topApps(limit: limit)
        isRefreshing = false
    }

    func refreshWhileVisible(refreshIntervalNanoseconds: UInt64 = 3_000_000_000) async {
        await refresh()
        while Task.isCancelled == false {
            do {
                try await sleep(refreshIntervalNanoseconds)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            entries = provider.topApps(limit: limit)
        }
    }
}
