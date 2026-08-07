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
    private let initialWindowNanoseconds: UInt64
    private let clock: any EnergyImpactClock
    private let sleep: (UInt64) async throws -> Void
    private let smoothingOverrideForTesting: ((
        EnergyImpactProcessIdentity,
        Double,
        TimeInterval
    ) -> Double?)?
    private let configuration = EnergyImpactConfiguration.production

    private var smoother = EnergyImpactSmoother(
        halfLifeSeconds: EnergyImpactConfiguration.production.fastHalfLifeSeconds
    )
    private var ranker = StableEnergyImpactRanker()
    private var lastValidObservationTimes: [EnergyImpactProcessIdentity: TimeInterval] = [:]
    private var lastPublicationTime: TimeInterval?

    init(
        provider: any EnergyImpactProviding = EnergyImpactService(),
        limit: Int = 20,
        initialWindowNanoseconds: UInt64 = 3_000_000_000,
        clock: any EnergyImpactClock = SystemEnergyImpactClock(),
        smoothingOverrideForTesting: ((EnergyImpactProcessIdentity, Double, TimeInterval) -> Double?)? = nil,
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.provider = provider
        self.limit = limit
        self.initialWindowNanoseconds = initialWindowNanoseconds
        self.clock = clock
        self.sleep = sleep
        self.smoothingOverrideForTesting = smoothingOverrideForTesting
    }

    func refresh() async {
        isRefreshing = true
        _ = provider.topApps(limit: .max)
        do {
            try await sleep(initialWindowNanoseconds)
        } catch {
            isRefreshing = false
            return
        }
        guard Task.isCancelled == false else {
            isRefreshing = false
            return
        }
        publish(provider.topApps(limit: .max), at: clock.nowSeconds())
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
            publish(provider.topApps(limit: .max), at: clock.nowSeconds())
        }
    }

    private func publish(_ candidates: [EnergyImpactEntry], at publicationTime: TimeInterval) {
        guard publicationTime.isFinite else {
            resetStatistics()
            entries = Array(
                ranker.rank(
                    candidates.map(Self.sanitizedForInvalidClock),
                    atPublicationBoundary: true
                )
                    .prefix(max(0, limit))
            )
            return
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
            process(candidate, at: publicationTime)
        }
        lastPublicationTime = publicationTime

        entries = Array(
            ranker.rank(processed, atPublicationBoundary: true)
                .prefix(max(0, limit))
        )
    }

    private func process(
        _ candidate: EnergyImpactEntry,
        at publicationTime: TimeInterval
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
        if let smoothingOverrideForTesting {
            smoothed = smoothingOverrideForTesting(
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

    private func resetStatistics() {
        smoother = EnergyImpactSmoother(halfLifeSeconds: configuration.fastHalfLifeSeconds)
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

    private static func nonnumericUnavailable(_ entry: EnergyImpactEntry) -> EnergyImpactEntry {
        nonnumeric(entry, status: .unavailable)
    }

    private static func sanitizedForInvalidClock(_ entry: EnergyImpactEntry) -> EnergyImpactEntry {
        let sanitized = sanitizingInvalidNumerics(entry)
        if sanitized.status == .stable || sanitized.status == .partial {
            return nonnumericUnavailable(sanitized)
        }
        return sanitized
    }

    private static func sanitizingInvalidNumerics(_ entry: EnergyImpactEntry) -> EnergyImpactEntry {
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
