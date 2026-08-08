import Darwin
import Foundation

public struct EnergyImpactSessionID: Hashable, Sendable {
    private let value: UUID

    public init() {
        value = UUID()
    }
}

public protocol EnergyImpactSampling: Sendable {
    func beginSession() async -> EnergyImpactSessionID
    func sample(
        sessionID: EnergyImpactSessionID,
        apps: [EnergyImpactAppSnapshot],
        limit: Int,
        publicationBoundary: Bool
    ) async -> [EnergyImpactEntry]?
    func endSession(_ sessionID: EnergyImpactSessionID) async
}

public actor EnergyImpactSampler: EnergyImpactSampling {
    private let reader: any ProcessEnergyReadingProvider
    private let processSnapshotReader: any ProcessParentSnapshotReading
    private let clock: any EnergyImpactClock
    private let configuration: EnergyImpactConfiguration
    private let processSnapshotRefreshIntervalSeconds: TimeInterval
    private let minimumProcessReadIntervalSeconds: TimeInterval
    private let smoothingOverrideForTesting: (@Sendable (
        EnergyImpactProcessIdentity,
        Double,
        TimeInterval
    ) -> Double?)?

    private var activeSessionID: EnergyImpactSessionID?
    private var state: EnergyImpactSamplerState

    public init(
        reader: any ProcessEnergyReadingProvider = SystemProcessEnergyReader(),
        processSnapshotReader: any ProcessParentSnapshotReading = SystemProcessParentSnapshotReader(),
        clock: any EnergyImpactClock = SystemEnergyImpactClock(),
        configuration: EnergyImpactConfiguration = .production
    ) {
        self.reader = reader
        self.processSnapshotReader = processSnapshotReader
        self.clock = clock
        self.configuration = configuration
        processSnapshotRefreshIntervalSeconds = configuration.publicationIntervalSeconds
        minimumProcessReadIntervalSeconds = configuration.sampleIntervalSeconds * 2
        smoothingOverrideForTesting = nil
        state = EnergyImpactSamplerState(configuration: configuration)
    }

    init(
        reader: any ProcessEnergyReadingProvider,
        processSnapshotReader: any ProcessParentSnapshotReading,
        clock: any EnergyImpactClock,
        configuration: EnergyImpactConfiguration,
        processSnapshotRefreshIntervalSeconds: TimeInterval,
        minimumProcessReadIntervalSeconds: TimeInterval
    ) {
        self.reader = reader
        self.processSnapshotReader = processSnapshotReader
        self.clock = clock
        self.configuration = configuration
        self.processSnapshotRefreshIntervalSeconds = processSnapshotRefreshIntervalSeconds
        self.minimumProcessReadIntervalSeconds = minimumProcessReadIntervalSeconds
        smoothingOverrideForTesting = nil
        state = EnergyImpactSamplerState(configuration: configuration)
    }

    init(
        reader: any ProcessEnergyReadingProvider,
        processSnapshotReader: any ProcessParentSnapshotReading,
        clock: any EnergyImpactClock,
        configuration: EnergyImpactConfiguration,
        smoothingOverrideForTesting: @escaping @Sendable (
            EnergyImpactProcessIdentity,
            Double,
            TimeInterval
        ) -> Double?
    ) {
        self.reader = reader
        self.processSnapshotReader = processSnapshotReader
        self.clock = clock
        self.configuration = configuration
        processSnapshotRefreshIntervalSeconds = configuration.publicationIntervalSeconds
        minimumProcessReadIntervalSeconds = configuration.sampleIntervalSeconds * 2
        self.smoothingOverrideForTesting = smoothingOverrideForTesting
        state = EnergyImpactSamplerState(configuration: configuration)
    }

    public func beginSession() async -> EnergyImpactSessionID {
        let sessionID = EnergyImpactSessionID()
        activeSessionID = sessionID
        state = EnergyImpactSamplerState(configuration: configuration)
        return sessionID
    }

    public func sample(
        sessionID: EnergyImpactSessionID,
        apps: [EnergyImpactAppSnapshot],
        limit: Int,
        publicationBoundary: Bool
    ) async -> [EnergyImpactEntry]? {
        guard canContinue(sessionID) else { return nil }

        var localState = state
        let sampleTime = clock.nowSeconds()
        let rootProcessIdentifiers = apps.map(\.processIdentifier)
        let rootProcessIdentifierSet = Set(rootProcessIdentifiers)
        let shouldReadProcesses = localState.shouldReadProcesses(
            at: sampleTime,
            rootProcessIdentifiers: rootProcessIdentifierSet,
            minimumIntervalSeconds: minimumProcessReadIntervalSeconds
        )
        if shouldReadProcesses == false, publicationBoundary == false {
            guard let cached = localState.cachedRawEntries,
                  canContinue(sessionID) else { return nil }
            return Self.sortedByImpact(
                Self.updatingMetadata(in: cached, from: apps),
                limit: limit
            )
        }

        let observationInterval = shouldReadProcesses
            ? localState.prepareForSample(at: sampleTime, configuration: configuration)
            : nil
        guard canContinue(sessionID) else { return nil }
        let processIdentifiersByRoot: [pid_t: [pid_t]]
        if localState.shouldRefreshProcessSnapshots(
            at: sampleTime,
            rootProcessIdentifiers: rootProcessIdentifierSet,
            publicationBoundary: publicationBoundary,
            refreshIntervalSeconds: processSnapshotRefreshIntervalSeconds
        ) {
            let processSnapshots = processSnapshotReader.snapshots()
            guard canContinue(sessionID) else { return nil }
            let owners = EnergyImpactOwnership.nearestRootOwners(
                rootProcessIdentifiers: rootProcessIdentifiers,
                snapshots: processSnapshots
            )
            localState.invalidateObservedOwnerTransitions(
                snapshots: processSnapshots,
                owners: owners
            )
            processIdentifiersByRoot = Dictionary(
                grouping: owners.keys,
                by: { owners[$0]! }
            )
            localState.storeProcessOwnership(
                snapshots: processSnapshots,
                processIdentifiersByRoot: processIdentifiersByRoot,
                rootProcessIdentifiers: rootProcessIdentifierSet,
                at: sampleTime
            )
        } else {
            processIdentifiersByRoot = localState.cachedProcessIdentifiersByRoot
        }
        guard canContinue(sessionID) else { return nil }
        if shouldReadProcesses == false {
            guard let cached = localState.cachedRawEntries else { return nil }
            let entries = Self.updatingMetadata(in: cached, from: apps)
            let result = localState.publish(
                entries,
                at: sampleTime,
                limit: limit,
                smoothingOverrideForTesting: smoothingOverrideForTesting
            )
            guard canContinue(sessionID) else { return nil }
            state = localState
            return result
        }
        var entries = [EnergyImpactEntry]()
        entries.reserveCapacity(apps.count)

        for app in apps {
            guard canContinue(sessionID) else { return nil }
            let processIdentifiers = (
                processIdentifiersByRoot[app.processIdentifier] ?? [app.processIdentifier]
            ).sorted { lhs, rhs in
                if lhs == app.processIdentifier { return true }
                if rhs == app.processIdentifier { return false }
                return lhs < rhs
            }
            var contributions = [ProcessEnergyContribution]()
            var readableProcessCount = 0
            var unsupportedProcessCount = 0

            for processIdentifier in processIdentifiers {
                guard canContinue(sessionID) else { return nil }
                if let identity = localState.identityByProcessIdentifier[processIdentifier],
                   let baseline = localState.baselines[identity],
                   baseline.ownerRootProcessIdentifier != app.processIdentifier {
                    localState.removeBaseline(for: identity)
                }

                switch reader.reading(for: processIdentifier) {
                case let .failure(failure):
                    let baseline = localState.identityByProcessIdentifier[processIdentifier]
                        .flatMap { localState.baselines[$0] }
                    if failure == .unsupported || baseline?.counterUnsupported == true {
                        unsupportedProcessCount += 1
                        if failure == .unsupported,
                           let identity = localState.identityByProcessIdentifier[processIdentifier],
                           let existing = localState.baselines[identity] {
                            localState.baselines[identity] = existing.markingCounterUnsupported()
                        }
                    }

                case let .success(current):
                    let identity = EnergyImpactProcessIdentity(
                        processIdentifier: processIdentifier,
                        processStartAbsoluteTime: current.processStartAbsoluteTime
                    )
                    if let oldIdentity = localState.identityByProcessIdentifier[processIdentifier],
                       oldIdentity != identity {
                        localState.removeBaseline(for: oldIdentity)
                    }
                    localState.identityByProcessIdentifier[processIdentifier] = identity

                    if processIdentifier == app.processIdentifier {
                        let appIdentity = EnergyImpactAppIdentity(
                            rootProcessIdentifier: processIdentifier,
                            rootProcessStartAbsoluteTime: current.processStartAbsoluteTime
                        )
                        if let oldIdentity = localState.currentIdentityByRootProcessIdentifier[
                            processIdentifier
                        ], oldIdentity != appIdentity {
                            localState.displayByIdentity.removeValue(forKey: oldIdentity)
                        }
                        localState.currentIdentityByRootProcessIdentifier[processIdentifier] = appIdentity
                    }

                    let previous = localState.baselines[identity]
                    let elapsed = previous.map { sampleTime - $0.sampleTime }
                    let canUsePrevious = observationInterval != nil
                        && previous?.ownerRootProcessIdentifier == app.processIdentifier
                        && elapsed.map {
                            $0 > 0 && $0 <= configuration.maximumGapSeconds
                        } == true
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
                                  current.userCPUTime > previous.reading.userCPUTime
                                    || current.systemCPUTime > previous.reading.systemCPUTime {
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

                    localState.baselines[identity] = ProcessEnergyBaseline(
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

            guard canContinue(sessionID) else { return nil }
            let identity = localState.currentIdentityByRootProcessIdentifier[app.processIdentifier]
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
            let previousDisplay = localState.displayByIdentity[identity]
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
                localState.displayByIdentity[publishedIdentity] = EnergyImpactDisplayState(
                    entry: entry,
                    sampleTime: sampleTime
                )
            } else if allProcessesUnsupported {
                localState.displayByIdentity.removeValue(forKey: identity)
            }
            entries.append(entry)
        }

        guard canContinue(sessionID) else { return nil }
        localState.prune(at: sampleTime, configuration: configuration)
        localState.storeRawEntries(entries, rootProcessIdentifiers: rootProcessIdentifierSet)
        let result = publicationBoundary
            ? localState.publish(
                entries,
                at: sampleTime,
                limit: limit,
                smoothingOverrideForTesting: smoothingOverrideForTesting
            )
            : Self.sortedByImpact(entries, limit: limit)

        guard canContinue(sessionID) else { return nil }
        state = localState
        return result
    }

    public func endSession(_ sessionID: EnergyImpactSessionID) async {
        guard sessionID == activeSessionID else { return }
        activeSessionID = nil
        state = EnergyImpactSamplerState(configuration: configuration)
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

    private func canContinue(_ sessionID: EnergyImpactSessionID) -> Bool {
        Task.isCancelled == false && sessionID == activeSessionID
    }

    private nonisolated static func updatingMetadata(
        in entries: [EnergyImpactEntry],
        from apps: [EnergyImpactAppSnapshot]
    ) -> [EnergyImpactEntry] {
        let appByProcessIdentifier = Dictionary(
            apps.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries.map { entry in
            guard let app = appByProcessIdentifier[entry.processIdentifier] else {
                return entry
            }
            return EnergyImpactEntry(
                identity: entry.identity,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                kind: app.kind,
                currentPowerMicrowatts: entry.currentPowerMicrowatts,
                sustainedPowerMicrowatts: entry.sustainedPowerMicrowatts,
                rankingScore: entry.rankingScore,
                trend: entry.trend,
                coverage: entry.coverage,
                status: entry.status
            )
        }
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
}

private struct EnergyImpactSamplerState: Sendable {
    var baselines: [EnergyImpactProcessIdentity: ProcessEnergyBaseline] = [:]
    var identityByProcessIdentifier: [pid_t: EnergyImpactProcessIdentity] = [:]
    var currentIdentityByRootProcessIdentifier: [pid_t: EnergyImpactAppIdentity] = [:]
    var displayByIdentity: [EnergyImpactAppIdentity: EnergyImpactDisplayState] = [:]
    var previousSampleTime: TimeInterval?
    var publicationState: EnergyImpactPublicationState
    var cachedProcessSnapshots: [ProcessParentSnapshot]?
    var lastProcessSnapshotTime: TimeInterval?
    var cachedRootProcessIdentifiers: Set<pid_t>?
    var cachedProcessIdentifiersByRoot: [pid_t: [pid_t]] = [:]
    var cachedRawEntries: [EnergyImpactEntry]?
    var cachedRawRootProcessIdentifiers: Set<pid_t>?

    init(configuration: EnergyImpactConfiguration) {
        publicationState = EnergyImpactPublicationState(configuration: configuration)
    }

    mutating func prepareForSample(
        at sampleTime: TimeInterval,
        configuration: EnergyImpactConfiguration
    ) -> Range<TimeInterval>? {
        let observationInterval: Range<TimeInterval>?
        if let previousSampleTime {
            let elapsed = sampleTime - previousSampleTime
            observationInterval = elapsed > 0 && elapsed <= configuration.maximumGapSeconds
                ? previousSampleTime..<sampleTime
                : nil
            if observationInterval == nil {
                baselines.removeAll()
                identityByProcessIdentifier.removeAll()
            }
        } else {
            observationInterval = nil
        }
        previousSampleTime = sampleTime
        prune(at: sampleTime, configuration: configuration)
        return observationInterval
    }

    func shouldReadProcesses(
        at sampleTime: TimeInterval,
        rootProcessIdentifiers: Set<pid_t>,
        minimumIntervalSeconds: TimeInterval
    ) -> Bool {
        guard cachedRawEntries != nil,
              cachedRawRootProcessIdentifiers == rootProcessIdentifiers,
              let previousSampleTime,
              minimumIntervalSeconds > 0,
              sampleTime.isFinite,
              previousSampleTime.isFinite else {
            return true
        }
        let age = sampleTime - previousSampleTime
        return age < 0 || age >= minimumIntervalSeconds
    }

    mutating func storeRawEntries(
        _ entries: [EnergyImpactEntry],
        rootProcessIdentifiers: Set<pid_t>
    ) {
        cachedRawEntries = entries
        cachedRawRootProcessIdentifiers = rootProcessIdentifiers
    }

    mutating func prune(
        at sampleTime: TimeInterval,
        configuration: EnergyImpactConfiguration
    ) {
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

    func shouldRefreshProcessSnapshots(
        at sampleTime: TimeInterval,
        rootProcessIdentifiers: Set<pid_t>,
        publicationBoundary: Bool,
        refreshIntervalSeconds: TimeInterval
    ) -> Bool {
        guard cachedProcessSnapshots != nil,
              let lastProcessSnapshotTime,
              cachedRootProcessIdentifiers == rootProcessIdentifiers,
              refreshIntervalSeconds > 0,
              sampleTime.isFinite,
              lastProcessSnapshotTime.isFinite else {
            return true
        }
        let age = sampleTime - lastProcessSnapshotTime
        return publicationBoundary || age < 0 || age >= refreshIntervalSeconds
    }

    mutating func storeProcessOwnership(
        snapshots: [ProcessParentSnapshot],
        processIdentifiersByRoot: [pid_t: [pid_t]],
        rootProcessIdentifiers: Set<pid_t>,
        at sampleTime: TimeInterval
    ) {
        cachedProcessSnapshots = snapshots
        cachedProcessIdentifiersByRoot = processIdentifiersByRoot
        cachedRootProcessIdentifiers = rootProcessIdentifiers
        lastProcessSnapshotTime = sampleTime
    }

    mutating func invalidateObservedOwnerTransitions(
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

    mutating func removeBaseline(for identity: EnergyImpactProcessIdentity) {
        baselines.removeValue(forKey: identity)
        if identityByProcessIdentifier[identity.processIdentifier] == identity {
            identityByProcessIdentifier.removeValue(forKey: identity.processIdentifier)
        }
    }

    mutating func publish(
        _ candidates: [EnergyImpactEntry],
        at publicationTime: TimeInterval,
        limit: Int,
        smoothingOverrideForTesting: (@Sendable (
            EnergyImpactProcessIdentity,
            Double,
            TimeInterval
        ) -> Double?)?
    ) -> [EnergyImpactEntry] {
        if let smoothingOverrideForTesting {
            return publicationState.publish(
                candidates,
                at: publicationTime,
                limit: limit,
                smoothingOverrideForTesting: smoothingOverrideForTesting
            )
        }
        return publicationState.publish(
            candidates,
            at: publicationTime,
            limit: limit
        )
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
