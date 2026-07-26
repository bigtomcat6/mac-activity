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
        sleep: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.provider = provider
        self.limit = limit
        self.initialWindowNanoseconds = initialWindowNanoseconds
        self.clock = clock
        self.sleep = sleep
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
                ranker.rank(candidates.map(Self.nonnumericUnavailable), atPublicationBoundary: true)
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
        guard candidate.status == .stable || candidate.status == .partial else {
            return candidate
        }
        guard let currentPower = candidate.currentPowerMicrowatts,
              let rankingScore = candidate.rankingScore,
              currentPower.isFinite,
              currentPower >= 0,
              rankingScore.isFinite,
              rankingScore >= 0 else {
            return Self.nonnumericUnavailable(candidate)
        }
        guard let generation = candidate.identity.generation else {
            return candidate
        }

        let elapsedSeconds: TimeInterval
        if let lastValidObservationTime = lastValidObservationTimes[generation] {
            elapsedSeconds = publicationTime - lastValidObservationTime
        } else {
            elapsedSeconds = configuration.publicationIntervalSeconds
        }
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            return Self.nonnumericUnavailable(candidate)
        }

        if elapsedSeconds > configuration.maximumGapSeconds {
            smoother.retainOnly(
                Set(lastValidObservationTimes.keys).subtracting([generation])
            )
            lastValidObservationTimes[generation] = nil
        }
        let smoothingElapsed = min(elapsedSeconds, configuration.maximumGapSeconds)
        guard let smoothed = smoother.update(
            identity: generation,
            value: currentPower,
            elapsedSeconds: smoothingElapsed
        ) else {
            return Self.nonnumericUnavailable(candidate)
        }
        lastValidObservationTimes[generation] = publicationTime
        return Self.replacingCurrentPower(in: candidate, with: smoothed)
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
            status: .unavailable
        )
    }
}
