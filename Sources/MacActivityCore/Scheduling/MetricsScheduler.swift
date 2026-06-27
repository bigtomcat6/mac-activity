import Foundation

public struct MetricsSamplingProfile: Equatable, Sendable {
    private static let inactiveMemorySamplingInterval = 11 * 60
    private let cadenceOverrides: [MetricKind: Int]

    public init(cadenceOverrides: [MetricKind: Int] = [:]) {
        self.cadenceOverrides = cadenceOverrides.mapValues { max(1, $0) }
    }

    public func interval(
        for kind: MetricKind,
        defaultCadence: MetricCadenceLane
    ) -> Int {
        cadenceOverrides[kind] ?? defaultCadence.seconds
    }

    public static func custom(_ cadenceOverrides: [MetricKind: Int]) -> MetricsSamplingProfile {
        MetricsSamplingProfile(cadenceOverrides: cadenceOverrides)
    }

    public static let realtime = MetricsSamplingProfile()
    public static let balanced = MetricsSamplingProfile(
        cadenceOverrides: [
            .cpu: 2,
            .gpu: 2,
            .disk: 30,
            .swap: 15,
            .memory: 5,
            .vram: 5,
            .network: 2,
            .battery: 15,
            .temperature: 2,
            .fan: 2,
        ]
    )
    public static let background = MetricsSamplingProfile(
        cadenceOverrides: [
            .cpu: 2,
            .gpu: 2,
            .disk: 60,
            .swap: 60,
            .memory: inactiveMemorySamplingInterval,
            .vram: 10,
            .network: 2,
            .battery: 10,
            .temperature: 10,
            .fan: 10,
        ]
    )
    public static let energySaver = MetricsSamplingProfile(
        cadenceOverrides: [
            .cpu: 2,
            .gpu: 2,
            .disk: 120,
            .swap: 120,
            .memory: inactiveMemorySamplingInterval,
            .vram: 120,
            .network: 2,
            .battery: 120,
            .temperature: 60,
            .fan: 60,
        ]
    )
}

public actor MetricsScheduler {
    private let providers: [any MetricProvider]
    private let store: MetricsStore
    private var samplingProfile: MetricsSamplingProfile
    private var loopTask: Task<Void, Never>?

    public init(
        providers: [any MetricProvider],
        store: MetricsStore,
        samplingProfile: MetricsSamplingProfile = .realtime
    ) {
        self.providers = providers
        self.store = store
        self.samplingProfile = samplingProfile
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

    public func setSamplingProfile(_ samplingProfile: MetricsSamplingProfile) {
        self.samplingProfile = samplingProfile
    }

    public func runTick(_ tick: Int, timestamp: Date = .now) async {
        let samplingProfile = self.samplingProfile
        let dueProviders = providers.filter {
            tick.isMultiple(
                of: samplingProfile.interval(
                    for: $0.kind,
                    defaultCadence: $0.cadence
                )
            )
        }
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
