import Foundation

public struct EnergyImpactPublicationState: Sendable {
    private let configuration: EnergyImpactConfiguration
    private var smoother: EnergyImpactSmoother
    private var ranker = StableEnergyImpactRanker()
    private var lastValidObservationTimes:
        [EnergyImpactProcessIdentity: TimeInterval] = [:]
    private var lastPublicationTime: TimeInterval?

    public init(configuration: EnergyImpactConfiguration = .production) {
        self.configuration = configuration
        self.smoother = EnergyImpactSmoother(
            halfLifeSeconds: configuration.fastHalfLifeSeconds
        )
    }

    public mutating func publish(
        _ candidates: [EnergyImpactEntry],
        at publicationTime: TimeInterval,
        limit: Int
    ) -> [EnergyImpactEntry] {
        publish(
            candidates,
            at: publicationTime,
            limit: limit,
            smoothingOverride: nil
        )
    }

    mutating func publish(
        _ candidates: [EnergyImpactEntry],
        at publicationTime: TimeInterval,
        limit: Int,
        smoothingOverrideForTesting: @Sendable (
            EnergyImpactProcessIdentity,
            Double,
            TimeInterval
        ) -> Double?
    ) -> [EnergyImpactEntry] {
        withoutActuallyEscaping(smoothingOverrideForTesting) { smoothingOverride in
            publish(
                candidates,
                at: publicationTime,
                limit: limit,
                smoothingOverride: smoothingOverride
            )
        }
    }

    private mutating func publish(
        _ candidates: [EnergyImpactEntry],
        at publicationTime: TimeInterval,
        limit: Int,
        smoothingOverride: (@Sendable (
            EnergyImpactProcessIdentity,
            Double,
            TimeInterval
        ) -> Double?)?
    ) -> [EnergyImpactEntry] {
        guard publicationTime.isFinite else {
            resetStatistics()
            return Array(
                ranker.rank(
                    candidates.map(Self.sanitizedForInvalidClock),
                    atPublicationBoundary: true
                )
                    .prefix(max(0, limit))
            )
        }

        if let lastPublicationTime {
            let publicationGap = publicationTime - lastPublicationTime
            if publicationGap <= 0 || publicationGap > configuration.maximumGapSeconds {
                resetStatistics()
            }
        }

        let currentGenerations = Set(candidates.compactMap(\.identity.generation))
        smoother.retainOnly(currentGenerations)
        lastValidObservationTimes = lastValidObservationTimes.filter {
            currentGenerations.contains($0.key)
        }

        let processed = candidates.map { candidate in
            process(
                candidate,
                at: publicationTime,
                smoothingOverride: smoothingOverride
            )
        }
        lastPublicationTime = publicationTime

        return Array(
            ranker.rank(processed, atPublicationBoundary: true)
                .prefix(max(0, limit))
        )
    }

    private mutating func process(
        _ candidate: EnergyImpactEntry,
        at publicationTime: TimeInterval,
        smoothingOverride: (@Sendable (
            EnergyImpactProcessIdentity,
            Double,
            TimeInterval
        ) -> Double?)?
    ) -> EnergyImpactEntry {
        let sanitized = Self.sanitizingInvalidNumerics(candidate)
        guard sanitized.status == .stable || sanitized.status == .partial else {
            return sanitized
        }
        guard let currentPower = sanitized.currentPowerMicrowatts,
              let rankingScore = sanitized.rankingScore,
              currentPower.isFinite,
              currentPower >= 0,
              rankingScore.isFinite,
              rankingScore >= 0 else {
            return Self.nonnumericUnavailable(sanitized)
        }
        guard let generation = sanitized.identity.generation else {
            return sanitized
        }

        let elapsedSeconds: TimeInterval
        if let lastValidObservationTime = lastValidObservationTimes[generation] {
            elapsedSeconds = publicationTime - lastValidObservationTime
        } else {
            elapsedSeconds = configuration.publicationIntervalSeconds
        }
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            return Self.nonnumericUnavailable(sanitized)
        }

        if elapsedSeconds > configuration.maximumGapSeconds {
            smoother.retainOnly(
                Set(lastValidObservationTimes.keys).subtracting([generation])
            )
            lastValidObservationTimes[generation] = nil
        }
        let smoothingElapsed = min(elapsedSeconds, configuration.maximumGapSeconds)
        let smoothed: Double?
        if let smoothingOverride {
            smoothed = smoothingOverride(
                generation,
                currentPower,
                smoothingElapsed
            )
        } else {
            smoothed = smoother.update(
                identity: generation,
                value: currentPower,
                elapsedSeconds: smoothingElapsed
            )
        }
        guard let smoothed else {
            return Self.nonnumericUnavailable(sanitized)
        }
        lastValidObservationTimes[generation] = publicationTime
        return Self.replacingCurrentPower(in: sanitized, with: smoothed)
    }

    private mutating func resetStatistics() {
        smoother = EnergyImpactSmoother(
            halfLifeSeconds: configuration.fastHalfLifeSeconds
        )
        ranker.reset()
        lastValidObservationTimes.removeAll()
        lastPublicationTime = nil
    }

    private static func replacingCurrentPower(
        in entry: EnergyImpactEntry,
        with currentPower: Double
    ) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: entry.identity,
            name: entry.name,
            bundleIdentifier: entry.bundleIdentifier,
            bundleURL: entry.bundleURL,
            kind: entry.kind,
            currentPowerMicrowatts: currentPower,
            sustainedPowerMicrowatts: entry.sustainedPowerMicrowatts,
            rankingScore: currentPower,
            trend: entry.trend,
            coverage: entry.coverage,
            status: entry.status
        )
    }

    private static func nonnumericUnavailable(
        _ entry: EnergyImpactEntry
    ) -> EnergyImpactEntry {
        nonnumeric(entry, status: .unavailable)
    }

    private static func sanitizedForInvalidClock(
        _ entry: EnergyImpactEntry
    ) -> EnergyImpactEntry {
        let sanitized = sanitizingInvalidNumerics(entry)
        if sanitized.status == .stable || sanitized.status == .partial {
            return nonnumericUnavailable(sanitized)
        }
        return sanitized
    }

    private static func sanitizingInvalidNumerics(
        _ entry: EnergyImpactEntry
    ) -> EnergyImpactEntry {
        let numericValues = [
            entry.currentPowerMicrowatts,
            entry.sustainedPowerMicrowatts,
            entry.rankingScore,
        ].compactMap { $0 }
        guard numericValues.contains(where: { $0.isFinite == false || $0 < 0 }) else {
            return entry
        }
        let status: EnergyImpactStatus =
            entry.status == .stable || entry.status == .partial ? .unavailable : entry.status
        return nonnumeric(entry, status: status)
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
            status: status
        )
    }
}
