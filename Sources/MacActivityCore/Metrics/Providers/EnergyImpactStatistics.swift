import Foundation

public struct EnergyIntervalSample: Equatable, Sendable {
    public let endTimeSeconds: TimeInterval
    public let durationSeconds: TimeInterval
    public let contributions: [ProcessEnergyContribution]
    public let discoveredProcessSeconds: TimeInterval

    public init(
        endTimeSeconds: TimeInterval,
        durationSeconds: TimeInterval,
        contributions: [ProcessEnergyContribution],
        discoveredProcessSeconds: TimeInterval
    ) {
        self.endTimeSeconds = endTimeSeconds
        self.durationSeconds = durationSeconds
        self.contributions = contributions
        self.discoveredProcessSeconds = discoveredProcessSeconds
    }

    public var isValid: Bool {
        endTimeSeconds.isFinite
            && durationSeconds.isFinite && durationSeconds > 0
            && discoveredProcessSeconds.isFinite && discoveredProcessSeconds >= 0
            && contributions.allSatisfy {
                $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite
                    && $0.durationSeconds.isFinite && $0.durationSeconds > 0
                    && $0.energyMicrojoules.isFinite && $0.energyMicrojoules >= 0
            }
    }
}

public struct TimeWeightedEnergyWindow: Equatable, Sendable {
    public let windowSeconds: TimeInterval
    private var samples: [EnergyIntervalSample] = []

    public init(windowSeconds: TimeInterval) {
        precondition(windowSeconds.isFinite && windowSeconds > 0)
        self.windowSeconds = windowSeconds
    }

    @discardableResult
    public mutating func append(_ sample: EnergyIntervalSample) -> Bool {
        guard sample.isValid else { return false }
        if let lastSample = samples.last,
           sample.endTimeSeconds <= lastSample.endTimeSeconds {
            return false
        }

        samples.append(sample)
        trim(at: sample.endTimeSeconds)
        return true
    }

    private mutating func trim(at now: TimeInterval) {
        let cutoff = now - windowSeconds
        samples = samples.compactMap { sample in
            let start = sample.endTimeSeconds - sample.durationSeconds
            guard sample.endTimeSeconds > cutoff else { return nil }
            let keptStart = max(start, cutoff)
            let keptDuration = sample.endTimeSeconds - keptStart
            return EnergyIntervalSample(
                endTimeSeconds: sample.endTimeSeconds,
                durationSeconds: keptDuration,
                contributions: sample.contributions.compactMap {
                    $0.clipped(to: cutoff..<now)
                },
                discoveredProcessSeconds: sample.discoveredProcessSeconds
                    * (keptDuration / sample.durationSeconds)
            )
        }
    }

    public var totalEnergyMicrojoules: Double {
        samples.flatMap(\.contributions).reduce(0) { $0 + $1.energyMicrojoules }
    }

    public var totalDurationSeconds: TimeInterval {
        samples.reduce(0) { $0 + $1.durationSeconds }
    }

    public var validProcessSeconds: TimeInterval {
        samples.flatMap(\.contributions).reduce(0) { $0 + $1.durationSeconds }
    }

    public var discoveredDurationSeconds: TimeInterval {
        samples.reduce(0) { $0 + $1.discoveredProcessSeconds }
    }

    public var powerMicrowatts: Double? {
        guard totalDurationSeconds > 0, validProcessSeconds > 0 else { return nil }
        return totalEnergyMicrojoules / totalDurationSeconds
    }

    public var coverage: Double {
        guard discoveredDurationSeconds > 0 else { return 0 }
        return min(max(validProcessSeconds / discoveredDurationSeconds, 0), 1)
    }
}

public struct TimeAwareEnergyEMA: Equatable, Sendable {
    public let halfLifeSeconds: TimeInterval
    private var value: Double?

    public init(halfLifeSeconds: TimeInterval) {
        precondition(halfLifeSeconds > 0)
        self.halfLifeSeconds = halfLifeSeconds
    }

    public mutating func update(value newValue: Double, elapsedSeconds: TimeInterval) -> Double? {
        guard newValue.isFinite, newValue >= 0,
              elapsedSeconds.isFinite, elapsedSeconds > 0 else { return nil }
        guard let previous = value else {
            value = newValue
            return newValue
        }
        let alpha = 1 - pow(0.5, elapsedSeconds / halfLifeSeconds)
        let smoothed = alpha * newValue + (1 - alpha) * previous
        value = smoothed
        return smoothed
    }
}

struct EnergyImpactAccumulator: Sendable {
    private var fast: TimeAwareEnergyEMA
    private var sustained: TimeWeightedEnergyWindow
    private var pendingDurationSeconds: TimeInterval = 0
    private var pendingDiscoveredProcessSeconds: TimeInterval = 0
    private var pendingContributions: [ProcessEnergyContribution] = []

    init(configuration: EnergyImpactConfiguration) {
        fast = TimeAwareEnergyEMA(
            halfLifeSeconds: configuration.fastHalfLifeSeconds
        )
        sustained = TimeWeightedEnergyWindow(
            windowSeconds: configuration.sustainedWindowSeconds
        )
    }

    mutating func observe(
        sample: EnergyIntervalSample,
        rawPowerMicrowatts: Double?
    ) -> (
        fast: Double,
        sustained: Double?,
        score: Double?,
        trend: EnergyImpactTrend,
        coverage: Double,
        validProcessSeconds: TimeInterval,
        discoveredProcessSeconds: TimeInterval,
        observedWallSeconds: TimeInterval
    )? {
        guard sample.isValid else { return nil }
        pendingDurationSeconds += sample.durationSeconds
        pendingDiscoveredProcessSeconds += sample.discoveredProcessSeconds
        pendingContributions.append(contentsOf: sample.contributions)

        guard let rawPowerMicrowatts,
              rawPowerMicrowatts.isFinite,
              rawPowerMicrowatts >= 0 else {
            return nil
        }

        let elapsedSinceValidObservation = pendingDurationSeconds
        let committed = EnergyIntervalSample(
            endTimeSeconds: sample.endTimeSeconds,
            durationSeconds: elapsedSinceValidObservation,
            contributions: pendingContributions,
            discoveredProcessSeconds: pendingDiscoveredProcessSeconds
        )
        pendingDurationSeconds = 0
        pendingDiscoveredProcessSeconds = 0
        pendingContributions.removeAll(keepingCapacity: true)

        guard sustained.append(committed),
              let fastValue = fast.update(
                  value: rawPowerMicrowatts,
                  elapsedSeconds: elapsedSinceValidObservation
              ) else {
            return nil
        }

        let sustainedValue = sustained.powerMicrowatts
        let score = sustainedValue.map {
            0.4 * fastValue + 0.6 * $0
        }
        let trend = Self.trend(
            fast: fastValue,
            sustained: sustainedValue
        )
        return (
            fast: fastValue,
            sustained: sustainedValue,
            score: score,
            trend: trend,
            coverage: sustained.coverage,
            validProcessSeconds: sustained.validProcessSeconds,
            discoveredProcessSeconds: sustained.discoveredDurationSeconds,
            observedWallSeconds: sustained.totalDurationSeconds
        )
    }

    static func trend(
        fast: Double,
        sustained: Double?
    ) -> EnergyImpactTrend {
        guard let sustained else { return .steady }
        if fast > sustained * 1.15 { return .rising }
        if fast < sustained * 0.85 { return .falling }
        return .steady
    }
}

public struct StableEnergyImpactRanker: Sendable {
    private struct ChallengerPair: Hashable, Sendable {
        let challenger: EnergyImpactProcessIdentity
        let incumbent: EnergyImpactProcessIdentity
    }

    private var currentOrder: [EnergyImpactProcessIdentity] = []
    private var leadCounts: [ChallengerPair: Int] = [:]

    public init() {}

    public mutating func reset() {
        currentOrder.removeAll()
        leadCounts.removeAll()
    }

    public mutating func rank(
        _ entries: [EnergyImpactEntry],
        atPublicationBoundary: Bool
    ) -> [EnergyImpactEntry] {
        let buckets = Dictionary(grouping: entries, by: Self.statusBucket)
        let current = buckets[0, default: []]
        let lowerBuckets = [1, 2, 3].flatMap {
            buckets[$0, default: []].sorted(by: Self.deterministicBefore)
        }

        guard atPublicationBoundary else {
            return current.sorted(by: Self.deterministicBefore) + lowerBuckets
        }

        let statefulByGeneration = Dictionary(
            current.compactMap { entry in
                entry.identity.generation.map { ($0, entry) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let currentGenerations = Set(statefulByGeneration.keys)
        currentOrder.removeAll { currentGenerations.contains($0) == false }

        let newGenerations = currentGenerations.subtracting(Set(currentOrder)).sorted { lhs, rhs in
            guard let left = statefulByGeneration[lhs],
                  let right = statefulByGeneration[rhs] else { return false }
            return Self.deterministicBefore(left, right)
        }
        currentOrder.append(contentsOf: newGenerations)

        var movedImmediately = true
        while movedImmediately, currentOrder.count > 1 {
            movedImmediately = false
            for index in 1..<currentOrder.count {
                let incumbent = currentOrder[index - 1]
                let challenger = currentOrder[index]
                if leadRatio(
                    challenger: challenger,
                    incumbent: incumbent,
                    entries: statefulByGeneration
                ) >= 1.25 {
                    currentOrder.swapAt(index - 1, index)
                    movedImmediately = true
                }
            }
        }

        if currentOrder.count > 1 {
            for index in 1..<currentOrder.count {
                let incumbent = currentOrder[index - 1]
                let challenger = currentOrder[index]
                let pair = ChallengerPair(challenger: challenger, incumbent: incumbent)
                let ratio = leadRatio(
                    challenger: challenger,
                    incumbent: incumbent,
                    entries: statefulByGeneration
                )
                if ratio >= 1.10 {
                    let count = leadCounts[pair, default: 0] + 1
                    leadCounts[pair] = count
                    if count >= 2 {
                        currentOrder.swapAt(index - 1, index)
                        leadCounts[pair] = nil
                    }
                } else {
                    leadCounts[pair] = nil
                }
            }
        }

        let activePairs = Set(currentOrder.indices.dropFirst().map { index in
            ChallengerPair(
                challenger: currentOrder[index],
                incumbent: currentOrder[index - 1]
            )
        })
        leadCounts = leadCounts.filter { activePairs.contains($0.key) }
        let stateful = currentOrder.compactMap { statefulByGeneration[$0] }
        let ephemeral = current
            .filter { $0.identity.generation == nil }
            .sorted(by: Self.deterministicBefore)
        return stateful + ephemeral + lowerBuckets
    }

    private func score(
        for identity: EnergyImpactProcessIdentity,
        in entries: [EnergyImpactProcessIdentity: EnergyImpactEntry]
    ) -> Double {
        entries[identity]?.rankingScore ?? -.infinity
    }

    private func leadRatio(
        challenger: EnergyImpactProcessIdentity,
        incumbent: EnergyImpactProcessIdentity,
        entries: [EnergyImpactProcessIdentity: EnergyImpactEntry]
    ) -> Double {
        let challengerScore = score(for: challenger, in: entries)
        let incumbentScore = score(for: incumbent, in: entries)
        if incumbentScore <= 0 {
            return challengerScore > 0 ? .infinity : 1
        }
        return challengerScore / incumbentScore
    }

    private static func statusBucket(_ entry: EnergyImpactEntry) -> Int {
        if entry.status == .stale, entry.currentPowerMicrowatts != nil {
            return 1
        }
        if entry.rankingScore != nil {
            if entry.status == .stable || entry.status == .partial { return 0 }
        }
        switch entry.status {
        case .collecting: return 2
        case .unavailable, .stable, .partial, .stale: return 3
        }
    }

    private static func deterministicBefore(
        _ lhs: EnergyImpactEntry,
        _ rhs: EnergyImpactEntry
    ) -> Bool {
        let lhsScore = lhs.rankingScore ?? lhs.currentPowerMicrowatts ?? -.infinity
        let rhsScore = rhs.rankingScore ?? rhs.currentPowerMicrowatts ?? -.infinity
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.processIdentifier != rhs.processIdentifier {
            return lhs.processIdentifier < rhs.processIdentifier
        }
        return (lhs.identity.rootProcessStartAbsoluteTime ?? 0)
            < (rhs.identity.rootProcessStartAbsoluteTime ?? 0)
    }
}
