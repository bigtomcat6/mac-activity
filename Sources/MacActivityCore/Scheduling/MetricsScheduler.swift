import Foundation

public actor MetricsScheduler {
    private let providers: [any MetricProvider]
    private let store: MetricsStore
    private var loopTask: Task<Void, Never>?

    public init(providers: [any MetricProvider], store: MetricsStore) {
        self.providers = providers
        self.store = store
    }

    public func start() {
        guard loopTask == nil else {
            return
        }

        loopTask = Task { [self] in
            var tick = 0
            while !Task.isCancelled {
                await runTick(tick, timestamp: .now)
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    public func runTick(_ tick: Int, timestamp: Date = .now) async {
        let dueProviders = providers.filter { tick.isMultiple(of: $0.cadence.seconds) }
        guard !dueProviders.isEmpty else {
            return
        }

        let updates = await withTaskGroup(of: MetricUpdate.self) { group in
            for provider in dueProviders {
                group.addTask {
                    await provider.sample()
                }
            }

            var collected: [MetricUpdate] = []
            for await update in group {
                collected.append(update)
            }
            return collected
        }

        await store.apply(updates, timestamp: timestamp)
    }
}
