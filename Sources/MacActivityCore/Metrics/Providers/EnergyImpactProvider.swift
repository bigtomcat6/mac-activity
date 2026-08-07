import AppKit
import Darwin
import Foundation

public struct EnergyImpactAppSnapshot: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let kind: EnergyImpactAppKind

    public init(
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        bundleURL: URL?,
        kind: EnergyImpactAppKind = .regular
    ) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.kind = kind
    }
}

public struct ProcessEnergyReading: Equatable, Sendable {
    public let energyNanojoules: UInt64
    public let processStartAbsoluteTime: UInt64
    public let userCPUTime: UInt64
    public let systemCPUTime: UInt64

    public init(
        energyNanojoules: UInt64,
        processStartAbsoluteTime: UInt64 = 0,
        userCPUTime: UInt64 = 0,
        systemCPUTime: UInt64 = 0
    ) {
        self.energyNanojoules = energyNanojoules
        self.processStartAbsoluteTime = processStartAbsoluteTime
        self.userCPUTime = userCPUTime
        self.systemCPUTime = systemCPUTime
    }
}

@MainActor
public final class EnergyImpactService {
    private let reader: any ProcessEnergyReadingProvider
    private let processSnapshotReader: any ProcessParentSnapshotReading
    private let appSnapshotProvider: () -> [EnergyImpactAppSnapshot]
    private let clock: any EnergyImpactClock
    private let configuration: EnergyImpactConfiguration
    private var baselines: [EnergyImpactProcessIdentity: ProcessEnergyBaseline] = [:]
    private var identityByProcessIdentifier: [pid_t: EnergyImpactProcessIdentity] = [:]
    private var currentIdentityByRootProcessIdentifier: [pid_t: EnergyImpactAppIdentity] = [:]
    private var displayByIdentity: [EnergyImpactAppIdentity: EnergyImpactDisplayState] = [:]
    private var previousSampleTime: TimeInterval?

    public init(
        workspace: NSWorkspace = .shared,
        reader: any ProcessEnergyReadingProvider = SystemProcessEnergyReader(),
        processSnapshotReader: any ProcessParentSnapshotReading = SystemProcessParentSnapshotReader(),
        appSnapshotProvider: (() -> [EnergyImpactAppSnapshot])? = nil,
        clock: any EnergyImpactClock = SystemEnergyImpactClock(),
        configuration: EnergyImpactConfiguration = .production
    ) {
        self.reader = reader
        self.processSnapshotReader = processSnapshotReader
        self.clock = clock
        self.configuration = configuration
        self.appSnapshotProvider = appSnapshotProvider ?? {
            workspace.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map {
                    EnergyImpactAppSnapshot(
                        processIdentifier: $0.processIdentifier,
                        name: $0.localizedName ?? $0.bundleIdentifier ?? "Process \($0.processIdentifier)",
                        bundleIdentifier: $0.bundleIdentifier,
                        bundleURL: $0.bundleURL
                    )
                }
        }
    }

    public func topApps(limit: Int = 20) -> [EnergyImpactEntry] {
        let samples = sampleApps()
        return Self.sortedByImpact(samples.map(\.entry), limit: limit)
    }

    private func sampleApps() -> [EnergyImpactAppSample] {
        let apps = appSnapshotProvider()
        let sampleTime = clock.nowSeconds()
        let observationInterval: Range<TimeInterval>?
        let breaksBaselineContinuity: Bool
        if let previousSampleTime {
            let elapsed = sampleTime - previousSampleTime
            observationInterval = elapsed > 0 && elapsed <= configuration.maximumGapSeconds
                ? previousSampleTime..<sampleTime
                : nil
            breaksBaselineContinuity = observationInterval == nil
        } else {
            observationInterval = nil
            breaksBaselineContinuity = false
        }
        self.previousSampleTime = sampleTime
        if breaksBaselineContinuity {
            baselines.removeAll()
            identityByProcessIdentifier.removeAll()
        }
        pruneState(at: sampleTime)

        let processSnapshots = processSnapshotReader.snapshots()
        let owners = EnergyImpactOwnership.nearestRootOwners(
            rootProcessIdentifiers: apps.map(\.processIdentifier),
            snapshots: processSnapshots
        )
        invalidateObservedOwnerTransitions(
            snapshots: processSnapshots,
            owners: owners
        )
        let processIdentifiersByRoot = Dictionary(
            grouping: owners.keys,
            by: { owners[$0]! }
        )
        let samples = apps.map { app -> EnergyImpactAppSample in
            let processIdentifiers = (processIdentifiersByRoot[app.processIdentifier] ?? [app.processIdentifier])
                .sorted { lhs, rhs in
                    if lhs == app.processIdentifier { return true }
                    if rhs == app.processIdentifier { return false }
                    return lhs < rhs
                }
            var contributions: [ProcessEnergyContribution] = []
            var readableProcessCount = 0
            var unsupportedProcessCount = 0

            for processIdentifier in processIdentifiers {
                if let identity = identityByProcessIdentifier[processIdentifier],
                   let baseline = baselines[identity],
                   baseline.ownerRootProcessIdentifier != app.processIdentifier {
                    removeBaseline(for: identity)
                }
                switch reader.reading(for: processIdentifier) {
                case let .failure(failure):
                    let baseline = identityByProcessIdentifier[processIdentifier].flatMap { baselines[$0] }
                    if failure == .unsupported || baseline?.counterUnsupported == true {
                        unsupportedProcessCount += 1
                        if failure == .unsupported,
                           let identity = identityByProcessIdentifier[processIdentifier],
                           let existing = baselines[identity] {
                            baselines[identity] = existing.markingCounterUnsupported()
                        }
                    }

                case let .success(current):
                    let identity = EnergyImpactProcessIdentity(
                        processIdentifier: processIdentifier,
                        processStartAbsoluteTime: current.processStartAbsoluteTime
                    )
                    if let oldIdentity = identityByProcessIdentifier[processIdentifier],
                       oldIdentity != identity {
                        removeBaseline(for: oldIdentity)
                    }
                    identityByProcessIdentifier[processIdentifier] = identity

                    if processIdentifier == app.processIdentifier {
                        let appIdentity = EnergyImpactAppIdentity(
                            rootProcessIdentifier: processIdentifier,
                            rootProcessStartAbsoluteTime: current.processStartAbsoluteTime
                        )
                        if let oldIdentity = currentIdentityByRootProcessIdentifier[processIdentifier],
                           oldIdentity != appIdentity {
                            displayByIdentity.removeValue(forKey: oldIdentity)
                        }
                        currentIdentityByRootProcessIdentifier[processIdentifier] = appIdentity
                    }

                    let previous = baselines[identity]
                    let elapsed = previous.map { sampleTime - $0.sampleTime }
                    let canUsePrevious = observationInterval != nil
                        && previous?.ownerRootProcessIdentifier == app.processIdentifier
                        && elapsed.map { $0 > 0 && $0 <= configuration.maximumGapSeconds } == true
                    var zeroEnergyWithCPUActivitySeconds = canUsePrevious
                        ? previous?.zeroEnergyWithCPUActivitySeconds ?? 0
                        : 0
                    var counterUnsupported = canUsePrevious
                        ? previous?.counterUnsupported ?? false
                        : false

                    if let previous, let elapsed, canUsePrevious,
                       current.energyNanojoules >= previous.reading.energyNanojoules {
                        if current.energyNanojoules > previous.reading.energyNanojoules {
                            zeroEnergyWithCPUActivitySeconds = 0
                            counterUnsupported = false
                        } else if current.energyNanojoules == 0,
                                  previous.reading.energyNanojoules == 0,
                                  (current.userCPUTime > previous.reading.userCPUTime
                                      || current.systemCPUTime > previous.reading.systemCPUTime) {
                            zeroEnergyWithCPUActivitySeconds += elapsed
                            if zeroEnergyWithCPUActivitySeconds >= configuration.maximumGapSeconds {
                                counterUnsupported = true
                            }
                        }

                        if counterUnsupported == false, observationInterval != nil {
                            contributions.append(ProcessEnergyContribution(
                                processIdentity: identity,
                                ownerRootProcessIdentifier: app.processIdentifier,
                                startTimeSeconds: previous.sampleTime,
                                endTimeSeconds: sampleTime,
                                energyMicrojoules: Double(
                                    current.energyNanojoules - previous.reading.energyNanojoules
                                ) / 1_000.0
                            ))
                        }
                    } else if previous != nil {
                        zeroEnergyWithCPUActivitySeconds = 0
                        counterUnsupported = false
                    }

                    baselines[identity] = ProcessEnergyBaseline(
                        reading: current,
                        sampleTime: sampleTime,
                        lastObservedAt: sampleTime,
                        ownerRootProcessIdentifier: app.processIdentifier,
                        zeroEnergyWithCPUActivitySeconds: zeroEnergyWithCPUActivitySeconds,
                        counterUnsupported: counterUnsupported
                    )
                    if counterUnsupported {
                        unsupportedProcessCount += 1
                    } else {
                        readableProcessCount += 1
                    }
                }
            }

            let identity = currentIdentityByRootProcessIdentifier[app.processIdentifier]
                ?? EnergyImpactAppIdentity(
                    rootProcessIdentifier: app.processIdentifier,
                    rootProcessStartAbsoluteTime: nil
                )
            let clipped = observationInterval.map { interval in
                contributions.compactMap { $0.clipped(to: interval) }
            } ?? []
            let energyMicrojoules = clipped.reduce(0) { $0 + $1.energyMicrojoules }
            let validProcessSeconds = clipped.reduce(0) { $0 + $1.durationSeconds }
            let observationDuration = observationInterval.map {
                $0.upperBound - $0.lowerBound
            } ?? 0
            let discoveredProcessSeconds = Double(processIdentifiers.count) * observationDuration
            let currentPowerMicrowatts = validProcessSeconds > 0 && observationDuration > 0
                ? energyMicrojoules / observationDuration
                : nil
            let currentCoverage = EnergyImpactCoverage(
                discoveredProcessCount: processIdentifiers.count,
                readableProcessCount: readableProcessCount,
                validProcessSeconds: validProcessSeconds,
                discoveredProcessSeconds: discoveredProcessSeconds
            )
            let previousDisplay = displayByIdentity[identity]
            let displayAge = previousDisplay.map { sampleTime - $0.sampleTime }
            let canPublishStale = displayAge.map {
                $0 >= 0 && $0 <= configuration.maximumGapSeconds
            } == true
            let allProcessesUnsupported = processIdentifiers.isEmpty == false
                && unsupportedProcessCount == processIdentifiers.count

            let status: EnergyImpactStatus
            if allProcessesUnsupported {
                status = .unavailable
            } else if discoveredProcessSeconds > 0
                && validProcessSeconds >= discoveredProcessSeconds - 0.000_001 {
                status = .stable
            } else if validProcessSeconds > 0 {
                status = .partial
            } else if canPublishStale {
                status = .stale
            } else if readableProcessCount > 0 {
                status = .collecting
            } else {
                status = .unavailable
            }

            let publishedIdentity = status == .stale ? previousDisplay!.entry.identity : identity
            let publishedPower = status == .stale
                ? previousDisplay!.entry.currentPowerMicrowatts
                : (status == .stable || status == .partial ? currentPowerMicrowatts : nil)
            let publishedCoverage = status == .stale
                ? previousDisplay!.entry.coverage
                : currentCoverage
            let entry = EnergyImpactEntry(
                identity: publishedIdentity,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                kind: app.kind,
                currentPowerMicrowatts: publishedPower,
                sustainedPowerMicrowatts: nil,
                rankingScore: status == .stable || status == .partial ? publishedPower : nil,
                trend: .steady,
                coverage: publishedCoverage,
                status: status
            )

            if (status == .stable || status == .partial), publishedIdentity.generation != nil {
                displayByIdentity[publishedIdentity] = EnergyImpactDisplayState(
                    entry: entry,
                    sampleTime: sampleTime
                )
            } else if allProcessesUnsupported {
                displayByIdentity.removeValue(forKey: identity)
            }
            return EnergyImpactAppSample(entry: entry, contributions: contributions)
        }

        pruneState(at: sampleTime)
        return samples
    }

    public nonisolated static func sortedByImpact(
        _ entries: [EnergyImpactEntry],
        limit: Int
    ) -> [EnergyImpactEntry] {
        entries.sorted { lhs, rhs in
            let leftBucket = statusSortBucket(for: lhs)
            let rightBucket = statusSortBucket(for: rhs)
            if leftBucket != rightBucket { return leftBucket < rightBucket }

            let leftScore = lhs.rankingScore ?? lhs.currentPowerMicrowatts
            let rightScore = rhs.rankingScore ?? rhs.currentPowerMicrowatts
            switch (leftScore, rightScore) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.processIdentifier < rhs.processIdentifier
            }
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private nonisolated static func statusSortBucket(for entry: EnergyImpactEntry) -> Int {
        switch (entry.status, entry.currentPowerMicrowatts) {
        case (.stable, .some), (.partial, .some): 0
        case (.stale, .some): 1
        case (.collecting, _): 2
        case (.unavailable, _): 3
        default: 3
        }
    }

    private func pruneState(at sampleTime: TimeInterval) {
        let expiredIdentities = baselines.compactMap { identity, baseline in
            let age = sampleTime - baseline.lastObservedAt
            return age > configuration.maximumGapSeconds ? identity : nil
        }
        for identity in expiredIdentities {
            removeBaseline(for: identity)
        }

        displayByIdentity = displayByIdentity.filter { _, display in
            let age = sampleTime - display.sampleTime
            return age >= 0 && age <= configuration.maximumGapSeconds
        }
        identityByProcessIdentifier = identityByProcessIdentifier.filter {
            baselines[$0.value] != nil
        }
        currentIdentityByRootProcessIdentifier = currentIdentityByRootProcessIdentifier.filter {
            _, identity in
            identity.generation.map { baselines[$0] != nil } == true
        }
    }

    private func invalidateObservedOwnerTransitions(
        snapshots: [ProcessParentSnapshot],
        owners: [pid_t: pid_t]
    ) {
        for processIdentifier in Set(snapshots.map(\.processIdentifier)) {
            guard let identity = identityByProcessIdentifier[processIdentifier],
                  let baseline = baselines[identity],
                  owners[processIdentifier] != baseline.ownerRootProcessIdentifier else {
                continue
            }
            removeBaseline(for: identity)
        }
    }

    private func removeBaseline(for identity: EnergyImpactProcessIdentity) {
        baselines.removeValue(forKey: identity)
        if identityByProcessIdentifier[identity.processIdentifier] == identity {
            identityByProcessIdentifier.removeValue(forKey: identity.processIdentifier)
        }
    }
}

private struct ProcessEnergyBaseline: Sendable {
    let reading: ProcessEnergyReading
    let sampleTime: TimeInterval
    let lastObservedAt: TimeInterval
    let ownerRootProcessIdentifier: pid_t
    let zeroEnergyWithCPUActivitySeconds: TimeInterval
    let counterUnsupported: Bool

    func markingCounterUnsupported() -> ProcessEnergyBaseline {
        ProcessEnergyBaseline(
            reading: reading,
            sampleTime: sampleTime,
            lastObservedAt: lastObservedAt,
            ownerRootProcessIdentifier: ownerRootProcessIdentifier,
            zeroEnergyWithCPUActivitySeconds: zeroEnergyWithCPUActivitySeconds,
            counterUnsupported: true
        )
    }
}

private struct EnergyImpactDisplayState: Sendable {
    let entry: EnergyImpactEntry
    let sampleTime: TimeInterval
}

private struct EnergyImpactAppSample: Sendable {
    let entry: EnergyImpactEntry
    let contributions: [ProcessEnergyContribution]
}
