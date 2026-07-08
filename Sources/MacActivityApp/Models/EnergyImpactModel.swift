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

    init(provider: any EnergyImpactProviding = EnergyImpactService(), limit: Int = 20) {
        self.provider = provider
        self.limit = limit
    }

    func refresh() {
        isRefreshing = true
        entries = provider.topApps(limit: limit)
        isRefreshing = false
    }
}
