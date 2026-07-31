import Foundation

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

public struct EnergyImpactSmoother: Sendable {
    private let halfLifeSeconds: TimeInterval
    private var values: [EnergyImpactProcessIdentity: TimeAwareEnergyEMA] = [:]

    public init(halfLifeSeconds: TimeInterval) {
        self.halfLifeSeconds = halfLifeSeconds
    }

    public mutating func update(
        identity: EnergyImpactProcessIdentity,
        value: Double,
        elapsedSeconds: TimeInterval
    ) -> Double? {
        guard value.isFinite, value >= 0,
              elapsedSeconds.isFinite, elapsedSeconds > 0 else { return nil }
        var ema = values[identity] ?? TimeAwareEnergyEMA(halfLifeSeconds: halfLifeSeconds)
        guard let result = ema.update(value: value, elapsedSeconds: elapsedSeconds) else { return nil }
        values[identity] = ema
        return result
    }

    public mutating func retainOnly(_ identities: Set<EnergyImpactProcessIdentity>) {
        values = values.filter { identities.contains($0.key) }
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
