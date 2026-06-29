import XCTest
@testable import MacActivityCore

final class MetricsSchedulerTests: XCTestCase {
    func testRunTickSamplesProvidersByCadenceLane() async {
        let store = await MainActor.run { MetricsStore() }
        let fastProvider = SequencedProvider(
            kind: .cpu,
            cadence: .fast,
            updates: [
                .cpu(CPUReading(usagePercent: 10)),
                .cpu(CPUReading(usagePercent: 20)),
                .cpu(CPUReading(usagePercent: 30))
            ]
        )
        let mediumProvider = SequencedProvider(
            kind: .memory,
            cadence: .medium,
            updates: [
                .memory(MemoryReading(usedBytes: 1_000, totalBytes: 2_000)),
                .memory(MemoryReading(usedBytes: 1_500, totalBytes: 2_000))
            ]
        )
        let slowProvider = SequencedProvider(
            kind: .temperature,
            cadence: .slow,
            updates: [
                .temperature(TemperatureReading(celsius: 55))
            ]
        )

        let scheduler = MetricsScheduler(
            providers: [fastProvider, mediumProvider, slowProvider],
            store: store
        )

        await scheduler.runTick(0, timestamp: Date(timeIntervalSince1970: 100))
        await scheduler.runTick(1, timestamp: Date(timeIntervalSince1970: 101))
        await scheduler.runTick(2, timestamp: Date(timeIntervalSince1970: 102))

        let snapshot = await MainActor.run { store.snapshot }

        let fastCount = await fastProvider.readCount()
        let mediumCount = await mediumProvider.readCount()
        let slowCount = await slowProvider.readCount()

        XCTAssertEqual(fastCount, 3)
        XCTAssertEqual(mediumCount, 2)
        XCTAssertEqual(slowCount, 1)
        XCTAssertEqual(snapshot.cpu, CPUReading(usagePercent: 30))
        XCTAssertEqual(snapshot.memory, MemoryReading(usedBytes: 1_500, totalBytes: 2_000))
        XCTAssertEqual(snapshot.temperature, TemperatureReading(celsius: 55))
    }

    func testRunTickKeepsLastGoodReadingOnStaleFailureAndDropsUnsupportedSensor() async {
        let store = await MainActor.run { MetricsStore() }
        let cpuProvider = SequencedProvider(
            kind: .cpu,
            cadence: .fast,
            updates: [
                .cpu(CPUReading(usagePercent: 44)),
                .stale(kind: .cpu, reason: "Temporary error")
            ]
        )
        let temperatureProvider = SequencedProvider(
            kind: .temperature,
            cadence: .fast,
            updates: [
                .temperature(TemperatureReading(celsius: 58)),
                .unavailable(kind: .temperature, reason: "Sensor unavailable")
            ]
        )

        let scheduler = MetricsScheduler(
            providers: [cpuProvider, temperatureProvider],
            store: store
        )

        await scheduler.runTick(0, timestamp: Date(timeIntervalSince1970: 200))
        await scheduler.runTick(1, timestamp: Date(timeIntervalSince1970: 201))

        let snapshot = await MainActor.run { store.snapshot }

        XCTAssertEqual(snapshot.cpu, CPUReading(usagePercent: 44))
        XCTAssertEqual(snapshot.issues[.cpu], .stale("Temporary error"))
        XCTAssertNil(snapshot.temperature)
        XCTAssertEqual(snapshot.issues[.temperature], .unsupported("Sensor unavailable"))
    }

    func testSamplingProfileOverridesProviderCadence() async {
        let store = await MainActor.run { MetricsStore() }
        let cpuProvider = SequencedProvider(
            kind: .cpu,
            cadence: .fast,
            updates: [
                .cpu(CPUReading(usagePercent: 10)),
                .cpu(CPUReading(usagePercent: 20)),
                .cpu(CPUReading(usagePercent: 30))
            ]
        )
        let memoryProvider = SequencedProvider(
            kind: .memory,
            cadence: .medium,
            updates: [
                .memory(MemoryReading(usedBytes: 1_000, totalBytes: 2_000)),
                .memory(MemoryReading(usedBytes: 1_500, totalBytes: 2_000))
            ]
        )

        let scheduler = MetricsScheduler(
            providers: [cpuProvider, memoryProvider],
            store: store,
            samplingProfile: .custom([
                .cpu: 3,
                .memory: 5
            ])
        )

        await scheduler.runTick(0, timestamp: Date(timeIntervalSince1970: 300))
        await scheduler.runTick(1, timestamp: Date(timeIntervalSince1970: 301))
        await scheduler.runTick(2, timestamp: Date(timeIntervalSince1970: 302))
        await scheduler.runTick(3, timestamp: Date(timeIntervalSince1970: 303))
        await scheduler.runTick(4, timestamp: Date(timeIntervalSince1970: 304))
        await scheduler.runTick(5, timestamp: Date(timeIntervalSince1970: 305))

        let cpuCount = await cpuProvider.readCount()
        let memoryCount = await memoryProvider.readCount()

        XCTAssertEqual(cpuCount, 2)
        XCTAssertEqual(memoryCount, 2)
    }

    func testRealtimeProfileSamplesMemoryEveryTwoSeconds() {
        XCTAssertEqual(MemoryProvider().cadence, .medium)
        XCTAssertEqual(
            MetricsSamplingProfile.realtime.interval(for: .memory, defaultCadence: MemoryProvider().cadence),
            2
        )
    }

    func testBackgroundProfileRefreshesLiveMetricsEveryTwoSecondsAndMemoryEveryElevenMinutes() {
        XCTAssertEqual(
            MetricsSamplingProfile.background.interval(for: .cpu, defaultCadence: .fast),
            2
        )
        XCTAssertEqual(
            MetricsSamplingProfile.background.interval(for: .gpu, defaultCadence: .fast),
            2
        )
        XCTAssertEqual(
            MetricsSamplingProfile.background.interval(for: .network, defaultCadence: .fast),
            2
        )
        XCTAssertEqual(
            MetricsSamplingProfile.background.interval(for: .memory, defaultCadence: .medium),
            11 * 60
        )
        XCTAssertEqual(
            MetricsSamplingProfile.background.interval(for: .memory, defaultCadence: .medium),
            MetricsSamplingProfile.energySaver.interval(for: .memory, defaultCadence: .medium)
        )
        XCTAssertEqual(
            MetricsSamplingProfile.background.interval(for: .temperature, defaultCadence: .medium),
            10
        )
        XCTAssertEqual(
            MetricsSamplingProfile.background.interval(for: .fan, defaultCadence: .medium),
            10
        )
    }

    func testEnergySaverProfileUsesLowCadenceForExpensiveSensors() {
        XCTAssertEqual(TemperatureProvider().cadence, .medium)
        XCTAssertEqual(FanProvider().cadence, .medium)
        XCTAssertEqual(
            MetricsSamplingProfile.energySaver.interval(for: .cpu, defaultCadence: .fast),
            2
        )
        XCTAssertEqual(
            MetricsSamplingProfile.energySaver.interval(for: .gpu, defaultCadence: .fast),
            2
        )
        XCTAssertEqual(
            MetricsSamplingProfile.energySaver.interval(for: .network, defaultCadence: .fast),
            2
        )
        XCTAssertEqual(
            MetricsSamplingProfile.energySaver.interval(for: .memory, defaultCadence: .medium),
            11 * 60
        )
        XCTAssertEqual(
            MetricsSamplingProfile.energySaver.interval(for: .temperature, defaultCadence: .slow),
            60
        )
        XCTAssertEqual(
            MetricsSamplingProfile.energySaver.interval(for: .fan, defaultCadence: .slow),
            60
        )
    }
}

private actor SequencedProvider: MetricProvider {
    let kind: MetricKind
    let cadence: MetricCadenceLane

    private let updates: [MetricUpdate]
    private var index: Int = 0
    private(set) var callCount: Int = 0

    init(kind: MetricKind, cadence: MetricCadenceLane, updates: [MetricUpdate]) {
        self.kind = kind
        self.cadence = cadence
        self.updates = updates
    }

    func sample() async -> MetricUpdate {
        defer {
            callCount += 1
            index = min(index + 1, updates.count - 1)
        }
        return updates[index]
    }

    func readCount() -> Int {
        callCount
    }
}
