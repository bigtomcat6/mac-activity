import Combine
import Foundation

public struct MetricHistorySample: Equatable, Sendable {
    public var timestamp: Date
    public var primaryValue: Double
    public var secondaryValue: Double?
    var batteryIsConnectedToPower: Bool?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
    var memoryBreakdown: MemoryBreakdown?
    var sampleCount: Int

    init(
        timestamp: Date,
        primaryValue: Double,
        secondaryValue: Double? = nil,
        batteryIsConnectedToPower: Bool? = nil,
        memoryUsedBytes: UInt64? = nil,
        memoryTotalBytes: UInt64? = nil,
        memoryBreakdown: MemoryBreakdown? = nil,
        sampleCount: Int = 1
    ) {
        self.timestamp = timestamp
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.batteryIsConnectedToPower = batteryIsConnectedToPower
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryBreakdown = memoryBreakdown
        self.sampleCount = max(1, sampleCount)
    }

    init?(
        update: MetricUpdate,
        timestamp: Date
    ) {
        self.timestamp = timestamp
        self.sampleCount = 1
        self.batteryIsConnectedToPower = nil
        self.memoryUsedBytes = nil
        self.memoryTotalBytes = nil
        self.memoryBreakdown = nil

        switch update {
        case .cpu(let reading):
            self.primaryValue = reading.usagePercent
            self.secondaryValue = nil
        case .gpu(let reading):
            self.primaryValue = reading.usagePercent
            self.secondaryValue = nil
        case .memory(let reading):
            guard reading.totalBytes > 0 else {
                return nil
            }
            self.primaryValue = Double(reading.usedBytes) / Double(reading.totalBytes) * 100
            self.secondaryValue = nil
            self.memoryUsedBytes = reading.usedBytes
            self.memoryTotalBytes = reading.totalBytes
            self.memoryBreakdown = reading.breakdown
        case .vram(let reading):
            guard reading.totalBytes > 0 else {
                return nil
            }
            self.primaryValue = Double(reading.usedBytes) / Double(reading.totalBytes) * 100
            self.secondaryValue = nil
        case .disk(let reading):
            guard reading.totalBytes > 0 else {
                return nil
            }
            self.primaryValue = reading.usagePercent
            self.secondaryValue = nil
        case .swap(let reading):
            guard reading.totalBytes > 0 else {
                return nil
            }
            self.primaryValue = reading.usagePercent
            self.secondaryValue = nil
        case .network(let reading):
            self.primaryValue = max(0, reading.downloadBytesPerSecond)
            self.secondaryValue = max(0, reading.uploadBytesPerSecond)
        case .battery(let reading):
            self.primaryValue = reading.percentage
            self.secondaryValue = reading.hardwarePercentage
            self.batteryIsConnectedToPower = reading.isConnectedToPower
        case .temperature(let reading):
            self.primaryValue = reading.celsius
            self.secondaryValue = nil
        case .temperatures:
            return nil
        case .fan(let reading):
            self.primaryValue = Double(reading.rpm)
            self.secondaryValue = nil
        case .unavailable, .stale:
            return nil
        }
    }
}

public struct MetricsHistory: Equatable, Sendable {
    private struct RetentionPolicy: Equatable, Sendable {
        let window: TimeInterval
        let maxSamples: Int
        let recentSamplesToPreserve: Int
        let maximumContinuousSampleGap: TimeInterval

        static func forKind(_ kind: MetricKind) -> RetentionPolicy {
            switch kind {
            case .network:
                return RetentionPolicy(
                    window: 30 * 60,
                    maxSamples: 1_800,
                    recentSamplesToPreserve: 300,
                    maximumContinuousSampleGap: 10 * 60
                )
            case .cpu, .gpu, .disk, .swap, .memory, .vram, .battery, .temperature, .fan:
                return RetentionPolicy(
                    window: 24 * 60 * 60,
                    maxSamples: 1_440,
                    recentSamplesToPreserve: 300,
                    maximumContinuousSampleGap: 10 * 60
                )
            }
        }
    }

    private var samplesByKind: [MetricKind: [MetricHistorySample]]
    private var temperatureSamplesBySource: [TemperatureSource: [MetricHistorySample]]

    public init(
        samplesByKind: [MetricKind: [MetricHistorySample]] = [:],
        temperatureSamplesBySource: [TemperatureSource: [MetricHistorySample]] = [:]
    ) {
        self.init(
            samplesByKind: samplesByKind,
            temperatureSamplesBySource: temperatureSamplesBySource,
            trimReferenceDates: samplesByKind.mapValues { $0.last?.timestamp ?? .now },
            temperatureTrimReferenceDates: temperatureSamplesBySource.mapValues { $0.last?.timestamp ?? .now }
        )
    }

    public func samples(for kind: MetricKind, source: TemperatureSource? = nil) -> [MetricHistorySample] {
        if kind == .temperature, let source {
            return temperatureSamplesBySource[source] ?? []
        }

        return samplesByKind[kind] ?? []
    }

    public func appending(
        updates: [MetricUpdate],
        timestamp: Date
    ) -> MetricsHistory {
        var nextSamplesByKind = samplesByKind
        var nextTemperatureSamplesBySource = temperatureSamplesBySource

        for update in updates {
            switch update {
            case .temperature(let reading):
                let sample = MetricHistorySample(
                    timestamp: timestamp,
                    primaryValue: reading.celsius
                )
                nextSamplesByKind[.temperature] = Self.appending(
                    sample,
                    to: nextSamplesByKind[.temperature] ?? [],
                    kind: .temperature
                )
                nextTemperatureSamplesBySource[reading.source] = Self.appending(
                    sample,
                    to: nextTemperatureSamplesBySource[reading.source] ?? [],
                    kind: .temperature
                )
                continue
            case .temperatures(let readings):
                for reading in readings {
                    let sample = MetricHistorySample(
                        timestamp: timestamp,
                        primaryValue: reading.celsius
                    )
                    nextTemperatureSamplesBySource[reading.source] = Self.appending(
                        sample,
                        to: nextTemperatureSamplesBySource[reading.source] ?? [],
                        kind: .temperature
                    )
                }

                if let canonicalReading = readings.first(where: { $0.source == .smc }) ?? readings.first {
                    let sample = MetricHistorySample(
                        timestamp: timestamp,
                        primaryValue: canonicalReading.celsius
                    )
                    nextSamplesByKind[.temperature] = Self.appending(
                        sample,
                        to: nextSamplesByKind[.temperature] ?? [],
                        kind: .temperature
                    )
                }
                continue
            default:
                break
            }

            guard let sample = MetricHistorySample(update: update, timestamp: timestamp) else {
                continue
            }

            nextSamplesByKind[update.kind] = Self.appending(
                sample,
                to: nextSamplesByKind[update.kind] ?? [],
                kind: update.kind
            )
        }

        let trimReferenceDates = Dictionary(
            uniqueKeysWithValues: nextSamplesByKind.keys.map { ($0, timestamp) }
        )
        let temperatureTrimReferenceDates = Dictionary(
            uniqueKeysWithValues: nextTemperatureSamplesBySource.keys.map { ($0, timestamp) }
        )

        return MetricsHistory(
            samplesByKind: nextSamplesByKind,
            temperatureSamplesBySource: nextTemperatureSamplesBySource,
            trimReferenceDates: trimReferenceDates,
            temperatureTrimReferenceDates: temperatureTrimReferenceDates
        )
    }

    private init(
        samplesByKind: [MetricKind: [MetricHistorySample]],
        temperatureSamplesBySource: [TemperatureSource: [MetricHistorySample]],
        trimReferenceDates: [MetricKind: Date],
        temperatureTrimReferenceDates: [TemperatureSource: Date]
    ) {
        var retainedSamplesByKind: [MetricKind: [MetricHistorySample]] = [:]
        var retainedTemperatureSamplesBySource: [TemperatureSource: [MetricHistorySample]] = [:]

        for (kind, samples) in samplesByKind {
            let referenceDate = trimReferenceDates[kind] ?? samples.last?.timestamp ?? .now
            retainedSamplesByKind[kind] = Self.retainedSamples(
                from: samples,
                kind: kind,
                asOf: referenceDate
            )
        }

        for (source, samples) in temperatureSamplesBySource {
            let referenceDate = temperatureTrimReferenceDates[source] ?? samples.last?.timestamp ?? .now
            retainedTemperatureSamplesBySource[source] = Self.retainedSamples(
                from: samples,
                kind: .temperature,
                asOf: referenceDate
            )
        }

        self.samplesByKind = retainedSamplesByKind
        self.temperatureSamplesBySource = retainedTemperatureSamplesBySource
    }

    private static func appending(
        _ sample: MetricHistorySample,
        to existingSamples: [MetricHistorySample],
        kind: MetricKind
    ) -> [MetricHistorySample] {
        if startsNewContinuousSegment(sample, after: existingSamples.last, kind: kind) {
            return [sample]
        }

        return existingSamples + [sample]
    }

    private static func retainedSamples(
        from samples: [MetricHistorySample],
        kind: MetricKind,
        asOf referenceDate: Date
    ) -> [MetricHistorySample] {
        let policy = RetentionPolicy.forKind(kind)
        let cutoff = referenceDate.addingTimeInterval(-policy.window)
        let trimmed = samples.filter { $0.timestamp >= cutoff }

        guard trimmed.count > policy.maxSamples else {
            return trimmed
        }

        let recentCount = min(policy.recentSamplesToPreserve, policy.maxSamples, trimmed.count)
        let recentSamples = Array(trimmed.suffix(recentCount))
        let olderSamples = Array(trimmed.dropLast(recentCount))
        let olderTargetCount = max(0, policy.maxSamples - recentSamples.count)

        guard olderTargetCount > 0 else {
            return recentSamples
        }

        return bucketAveragedSamples(olderSamples, targetCount: olderTargetCount) + recentSamples
    }

    private static func startsNewContinuousSegment(
        _ sample: MetricHistorySample,
        after previousSample: MetricHistorySample?,
        kind: MetricKind
    ) -> Bool {
        guard let previousSample else {
            return false
        }

        let policy = RetentionPolicy.forKind(kind)
        return sample.timestamp.timeIntervalSince(previousSample.timestamp) > policy.maximumContinuousSampleGap
    }

    static func bucketAveragedSamples(
        _ samples: [MetricHistorySample],
        targetCount: Int
    ) -> [MetricHistorySample] {
        guard targetCount > 0, !samples.isEmpty else {
            return []
        }

        guard targetCount < samples.count else {
            return samples
        }

        return contiguousBucketAverages(samples, targetCount: targetCount)
    }

    private static func contiguousBucketAverages(
        _ samples: [MetricHistorySample],
        targetCount: Int
    ) -> [MetricHistorySample] {
        return (0..<targetCount).compactMap { bucketIndex in
            let startIndex = bucketIndex * samples.count / targetCount
            let endIndex = min(samples.count, (bucketIndex + 1) * samples.count / targetCount)
            guard startIndex < endIndex else {
                return nil
            }

            return averageBucket(Array(samples[startIndex..<endIndex]))
        }
    }

    private static func averageBucket(_ samples: [MetricHistorySample]) -> MetricHistorySample? {
        guard let lastSample = samples.last else {
            return nil
        }

        let totalSampleCount = samples.reduce(0) { partialResult, sample in
            partialResult + sample.sampleCount
        }
        let primaryAverage = samples.reduce(0) { partialResult, sample in
            partialResult + (sample.primaryValue * Double(sample.sampleCount))
        } / Double(totalSampleCount)
        let secondarySamples = samples.compactMap { sample -> (Double, Int)? in
            guard let secondaryValue = sample.secondaryValue else {
                return nil
            }

            return (secondaryValue, sample.sampleCount)
        }
        let secondaryAverage: Double?
        if secondarySamples.isEmpty {
            secondaryAverage = nil
        } else {
            let secondaryWeight = secondarySamples.reduce(0) { partialResult, sample in
                partialResult + sample.1
            }
            secondaryAverage = secondarySamples.reduce(0) { partialResult, sample in
                partialResult + (sample.0 * Double(sample.1))
            } / Double(secondaryWeight)
        }

        return MetricHistorySample(
            timestamp: lastSample.timestamp,
            primaryValue: primaryAverage,
            secondaryValue: secondaryAverage,
            batteryIsConnectedToPower: lastSample.batteryIsConnectedToPower,
            memoryUsedBytes: weightedMemoryBytes(
                from: samples,
                totalSampleCount: totalSampleCount,
                keyPath: \.memoryUsedBytes
            ),
            memoryTotalBytes: weightedMemoryBytes(
                from: samples,
                totalSampleCount: totalSampleCount,
                keyPath: \.memoryTotalBytes
            ),
            memoryBreakdown: weightedMemoryBreakdown(
                from: samples,
                totalSampleCount: totalSampleCount
            ),
            sampleCount: totalSampleCount
        )
    }

    private static func weightedMemoryBytes(
        from samples: [MetricHistorySample],
        totalSampleCount: Int,
        keyPath: KeyPath<MetricHistorySample, UInt64?>
    ) -> UInt64? {
        let values = samples.compactMap { sample -> (UInt64, Int)? in
            guard let value = sample[keyPath: keyPath] else {
                return nil
            }

            return (value, sample.sampleCount)
        }

        guard values.count == samples.count else {
            return nil
        }

        let weightedSum = values.reduce(0) { partialResult, value in
            partialResult + Double(value.0) * Double(value.1)
        }

        return UInt64((weightedSum / Double(totalSampleCount)).rounded())
    }

    private static func weightedMemoryBreakdown(
        from samples: [MetricHistorySample],
        totalSampleCount: Int
    ) -> MemoryBreakdown? {
        let values = samples.compactMap { sample -> (MemoryBreakdown, Int)? in
            guard let breakdown = sample.memoryBreakdown else {
                return nil
            }

            return (breakdown, sample.sampleCount)
        }

        guard values.count == samples.count else {
            return nil
        }

        return MemoryBreakdown(
            wiredBytes: weightedBreakdownBytes(
                values,
                totalSampleCount: totalSampleCount,
                keyPath: \.wiredBytes
            ),
            activeBytes: weightedBreakdownBytes(
                values,
                totalSampleCount: totalSampleCount,
                keyPath: \.activeBytes
            ),
            compressedBytes: weightedBreakdownBytes(
                values,
                totalSampleCount: totalSampleCount,
                keyPath: \.compressedBytes
            ),
            cachedBytes: weightedBreakdownBytes(
                values,
                totalSampleCount: totalSampleCount,
                keyPath: \.cachedBytes
            ),
            availableBytes: weightedBreakdownBytes(
                values,
                totalSampleCount: totalSampleCount,
                keyPath: \.availableBytes
            )
        )
    }

    private static func weightedBreakdownBytes(
        _ values: [(MemoryBreakdown, Int)],
        totalSampleCount: Int,
        keyPath: KeyPath<MemoryBreakdown, UInt64>
    ) -> UInt64 {
        let weightedSum = values.reduce(0) { partialResult, value in
            partialResult + Double(value.0[keyPath: keyPath]) * Double(value.1)
        }

        return UInt64((weightedSum / Double(totalSampleCount)).rounded())
    }
}

@MainActor
public final class MetricsStore: ObservableObject {
    @Published public private(set) var snapshot: MetricsSnapshot
    @Published public private(set) var history: MetricsHistory
    private let updatesSubject = PassthroughSubject<(MetricsSnapshot, MetricsHistory), Never>()

    public var updatesPublisher: AnyPublisher<(MetricsSnapshot, MetricsHistory), Never> {
        updatesSubject.eraseToAnyPublisher()
    }

    public init(snapshot: MetricsSnapshot = MetricsSnapshot(), history: MetricsHistory = MetricsHistory()) {
        self.snapshot = snapshot
        self.history = history
    }

    public func apply(_ updates: [MetricUpdate], timestamp: Date = .now) {
        snapshot = snapshot.applying(updates, timestamp: timestamp)
        history = history.appending(updates: updates, timestamp: timestamp)
        updatesSubject.send((snapshot, history))
    }
}
