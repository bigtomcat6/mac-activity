import Foundation

public struct EnergyImpactPublicationState: Sendable {
    private let configuration: EnergyImpactConfiguration
    private var ranker = StableEnergyImpactRanker()
    private var lastPublicationTime: TimeInterval?

    public init(configuration: EnergyImpactConfiguration = .production) {
        self.configuration = configuration
    }

    public mutating func publish(
        _ candidates: [EnergyImpactEntry],
        at publicationTime: TimeInterval,
        limit: Int
    ) -> [EnergyImpactEntry] {
        let hasValidClock = publicationTime.isFinite
        if hasValidClock == false {
            ranker.reset()
            lastPublicationTime = nil
        } else if let lastPublicationTime {
            let publicationGap = publicationTime - lastPublicationTime
            if publicationGap <= 0
                || publicationGap > configuration.maximumGapSeconds {
                ranker.reset()
            }
        }

        var seenGenerations = Set<EnergyImpactProcessIdentity>()
        let processed = candidates.map { candidate in
            let generation = candidate.identity.generation
            let isDuplicate = generation.map {
                seenGenerations.insert($0).inserted == false
            } ?? false
            if isDuplicate {
                return Self.nonnumericUnavailable(candidate)
            }
            let sanitized = Self.sanitizingFieldShape(candidate)
            if hasValidClock == false,
               sanitized.status == .stable || sanitized.status == .partial {
                return Self.nonnumericUnavailable(sanitized)
            }
            return sanitized
        }
        if hasValidClock {
            lastPublicationTime = publicationTime
        }

        let ranked = ranker.rank(
            processed,
            atPublicationBoundary: true
        )
        return Array(ranked.prefix(max(0, limit)))
    }

    private static func nonnumericUnavailable(
        _ entry: EnergyImpactEntry
    ) -> EnergyImpactEntry {
        nonnumeric(entry, status: .unavailable)
    }

    private static func sanitizingFieldShape(
        _ entry: EnergyImpactEntry
    ) -> EnergyImpactEntry {
        if entry.identity.generation == nil {
            let current = entry.currentPowerMicrowatts.flatMap {
                $0.isFinite && $0 >= 0 ? $0 : nil
            }
            return replacingFields(
                in: entry,
                current: current,
                sustained: nil,
                score: nil,
                status: .collecting
            )
        }
        let numericValues = [
            entry.currentPowerMicrowatts,
            entry.sustainedPowerMicrowatts,
            entry.rankingScore,
        ].compactMap { $0 }
        guard numericValues.contains(where: { $0.isFinite == false || $0 < 0 }) else {
            switch entry.status {
            case .stable, .partial:
                guard entry.currentPowerMicrowatts != nil,
                      entry.sustainedPowerMicrowatts != nil,
                      entry.rankingScore != nil else {
                    return nonnumericUnavailable(entry)
                }
                return entry
            case .stale:
                return replacingFields(
                    in: entry,
                    current: entry.currentPowerMicrowatts,
                    sustained: entry.sustainedPowerMicrowatts,
                    score: nil,
                    status: .stale
                )
            case .unavailable:
                return nonnumeric(entry, status: .unavailable)
            case .collecting:
                return entry
            }
        }
        let status: EnergyImpactStatus =
            entry.status == .stable || entry.status == .partial ? .unavailable : entry.status
        return nonnumeric(entry, status: status)
    }

    private static func replacingFields(
        in entry: EnergyImpactEntry,
        current: Double?,
        sustained: Double?,
        score: Double?,
        status: EnergyImpactStatus
    ) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: entry.identity,
            name: entry.name,
            bundleIdentifier: entry.bundleIdentifier,
            bundleURL: entry.bundleURL,
            kind: entry.kind,
            currentPowerMicrowatts: current,
            sustainedPowerMicrowatts: sustained,
            rankingScore: score,
            trend: entry.trend,
            coverage: entry.coverage,
            status: status,
            observedWindowSeconds: entry.observedWindowSeconds
        )
    }

    private static func nonnumeric(
        _ entry: EnergyImpactEntry,
        status: EnergyImpactStatus
    ) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: entry.identity,
            name: entry.name,
            bundleIdentifier: entry.bundleIdentifier,
            bundleURL: entry.bundleURL,
            kind: entry.kind,
            currentPowerMicrowatts: nil,
            sustainedPowerMicrowatts: nil,
            rankingScore: nil,
            trend: entry.trend,
            coverage: entry.coverage,
            status: status,
            observedWindowSeconds: entry.observedWindowSeconds
        )
    }
}
