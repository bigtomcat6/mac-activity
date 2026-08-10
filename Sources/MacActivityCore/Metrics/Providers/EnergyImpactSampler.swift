import Darwin
import Foundation

actor EnergyImpactSampler: EnergyImpactSampling {
    private let reader: any ProcessEnergyReadingProvider
    private let processSnapshotReader: any ProcessParentSnapshotReading
    private let clock: any EnergyImpactClock
    private let configuration: EnergyImpactConfiguration
    private var highestSeenRequestGeneration: UInt64 = 0
    private var activeLease: EnergyImpactSamplingLease?
    private var state: EnergyImpactSamplerState

    init(
        reader: any ProcessEnergyReadingProvider =
            SystemProcessEnergyReader(),
        processSnapshotReader: any ProcessParentSnapshotReading =
            SystemProcessParentSnapshotReader(),
        clock: any EnergyImpactClock = SystemEnergyImpactClock(),
        configuration: EnergyImpactConfiguration = .production
    ) {
        self.reader = reader
        self.processSnapshotReader = processSnapshotReader
        self.clock = clock
        self.configuration = configuration
        self.state = EnergyImpactSamplerState(configuration: configuration)
    }

    func beginSession(
        _ request: EnergyImpactSessionRequest
    ) -> EnergyImpactSamplingLease? {
        guard request.generation > highestSeenRequestGeneration else {
            return nil
        }
        highestSeenRequestGeneration = request.generation
        let lease = EnergyImpactSamplingLease(
            requestGeneration: request.generation
        )
        activeLease = lease
        state = EnergyImpactSamplerState(configuration: configuration)
        return lease
    }

    func observe(
        lease: EnergyImpactSamplingLease,
        apps: [EnergyImpactAppSnapshot],
        limit: Int
    ) -> [EnergyImpactEntry]? {
        guard canContinue(lease) else { return nil }
        var working = state
        let capturedAt = clock.nowSeconds()
        guard canContinue(lease) else { return nil }

        let processSnapshots = processSnapshotReader.snapshots()
        guard canContinue(lease) else { return nil }
        let owners = EnergyImpactOwnership.nearestRootOwners(
            rootProcessIdentifiers: apps.map(\.processIdentifier),
            snapshots: processSnapshots
        )
        let processIdentifiers = Set(owners.keys)
            .union(apps.map(\.processIdentifier))
            .filter { $0 > 0 }
            .sorted()
        var readingsByProcessIdentifier: [pid_t: ProcessEnergyReadResult] = [:]
        readingsByProcessIdentifier.reserveCapacity(processIdentifiers.count)
        for processIdentifier in processIdentifiers {
            guard canContinue(lease) else { return nil }
            readingsByProcessIdentifier[processIdentifier] = reader.reading(
                for: processIdentifier
            )
        }
        guard canContinue(lease) else { return nil }

        let observation = EnergyImpactObservation(
            sequence: working.sequence &+ 1,
            capturedAt: capturedAt,
            apps: apps,
            processSnapshots: processSnapshots,
            owners: owners,
            readingsByProcessIdentifier: readingsByProcessIdentifier
        )
        guard let candidates = buildCandidates(
            from: observation,
            lease: lease,
            working: &working
        ) else {
            return nil
        }
        let published = working.publicationState.publish(
            candidates,
            at: observation.capturedAt,
            limit: limit
        )
        guard canContinue(lease) else { return nil }
        working.sequence = observation.sequence
        state = working
        return published
    }

    func endSession(_ lease: EnergyImpactSamplingLease) {
        guard activeLease == lease else { return }
        activeLease = nil
        state = EnergyImpactSamplerState(configuration: configuration)
    }

    private func buildCandidates(
        from observation: EnergyImpactObservation,
        lease: EnergyImpactSamplingLease,
        working: inout EnergyImpactSamplerState
    ) -> [EnergyImpactEntry]? {
        let observationInterval: Range<TimeInterval>?
        let breaksBaselineContinuity: Bool
        if let previousObservationTime = working.previousObservationTime {
            let elapsed = observation.capturedAt - previousObservationTime
            observationInterval = elapsed > 0
                && elapsed <= configuration.maximumGapSeconds
                ? previousObservationTime..<observation.capturedAt
                : nil
            breaksBaselineContinuity = observationInterval == nil
        } else {
            observationInterval = nil
            breaksBaselineContinuity = false
        }
        working.previousObservationTime = observation.capturedAt
        if breaksBaselineContinuity {
            working.breakContinuity()
        }
        working.prune(at: observation.capturedAt, configuration: configuration)
        working.invalidateObservedOwnerTransitions(
            snapshots: observation.processSnapshots,
            owners: observation.owners
        )

        var rootsRequiringFreshInterval = Set<pid_t>()
        for app in observation.apps {
            guard case let .success(rootReading)? =
                observation.readingsByProcessIdentifier[app.processIdentifier] else {
                continue
            }
            let confirmedIdentity = EnergyImpactAppIdentity(
                rootProcessIdentifier: app.processIdentifier,
                rootProcessStartAbsoluteTime: rootReading.processStartAbsoluteTime
            )
            let previousIdentity =
                working.currentIdentityByRootProcessIdentifier[app.processIdentifier]
            guard let confirmedGeneration = confirmedIdentity.generation else {
                continue
            }
            if previousIdentity != confirmedIdentity
                || working.baselines[confirmedGeneration] == nil {
                rootsRequiringFreshInterval.insert(app.processIdentifier)
            }
            let hasUnconfirmedOwnedBaselines = previousIdentity == nil
                && working.baselines.values.contains {
                    $0.ownerRootProcessIdentifier == app.processIdentifier
                }
            if previousIdentity != nil && previousIdentity != confirmedIdentity
                || hasUnconfirmedOwnedBaselines {
                working.removeRootOwnedState(
                    rootProcessIdentifier: app.processIdentifier
                )
            }
        }

        let processIdentifiersByRoot = Dictionary(
            grouping: observation.owners.keys,
            by: { observation.owners[$0]! }
        )
        var candidates: [EnergyImpactEntry] = []
        candidates.reserveCapacity(observation.apps.count)
        for app in observation.apps {
            guard canContinue(lease) else { return nil }
            let processIdentifiers = Set(
                processIdentifiersByRoot[app.processIdentifier] ?? []
            )
            .union([app.processIdentifier])
            .sorted { lhs, rhs in
                if lhs == app.processIdentifier { return true }
                if rhs == app.processIdentifier { return false }
                return lhs < rhs
            }
            var contributions: [ProcessEnergyContribution] = []
            var readableProcessCount = 0
            var unsupportedProcessCount = 0

            for processIdentifier in processIdentifiers {
                guard canContinue(lease) else { return nil }
                if let identity = working.identityByProcessIdentifier[processIdentifier],
                   let baseline = working.baselines[identity],
                   baseline.ownerRootProcessIdentifier != app.processIdentifier {
                    working.removeBaseline(for: identity)
                }
                guard let result = observation.readingsByProcessIdentifier[processIdentifier] else {
                    continue
                }
                switch result {
                case let .failure(failure):
                    let baseline = working.identityByProcessIdentifier[processIdentifier]
                        .flatMap { working.baselines[$0] }
                    if failure == .unsupported || baseline?.counterUnsupported == true {
                        unsupportedProcessCount += 1
                        if failure == .unsupported,
                           let identity = working.identityByProcessIdentifier[processIdentifier],
                           let existing = working.baselines[identity] {
                            working.baselines[identity] = existing.markingCounterUnsupported()
                        }
                    }

                case let .success(current):
                    let identity = EnergyImpactProcessIdentity(
                        processIdentifier: processIdentifier,
                        processStartAbsoluteTime: current.processStartAbsoluteTime
                    )
                    if let oldIdentity = working.identityByProcessIdentifier[processIdentifier],
                       oldIdentity != identity {
                        working.removeBaseline(for: oldIdentity)
                    }
                    working.identityByProcessIdentifier[processIdentifier] = identity

                    if processIdentifier == app.processIdentifier {
                        let appIdentity = EnergyImpactAppIdentity(
                            rootProcessIdentifier: processIdentifier,
                            rootProcessStartAbsoluteTime: current.processStartAbsoluteTime
                        )
                        working.currentIdentityByRootProcessIdentifier[processIdentifier] = appIdentity
                    }

                    let previous = working.baselines[identity]
                    let elapsed = previous.map {
                        observation.capturedAt - $0.sampleTime
                    }
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
                                endTimeSeconds: observation.capturedAt,
                                energyMicrojoules: Double(
                                    current.energyNanojoules - previous.reading.energyNanojoules
                                ) / 1_000.0
                            ))
                        }
                    } else if previous != nil {
                        zeroEnergyWithCPUActivitySeconds = 0
                        counterUnsupported = false
                    }

                    working.baselines[identity] = ProcessEnergyBaseline(
                        reading: current,
                        sampleTime: observation.capturedAt,
                        lastObservedAt: observation.capturedAt,
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

            let identity = working.currentIdentityByRootProcessIdentifier[app.processIdentifier]
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
            let discoveredProcessSeconds = Double(processIdentifiers.count)
                * observationDuration
            let currentPowerMicrowatts = validProcessSeconds > 0
                && observationDuration > 0
                ? energyMicrojoules / observationDuration
                : nil
            let currentCoverage = EnergyImpactCoverage(
                discoveredProcessCount: processIdentifiers.count,
                readableProcessCount: readableProcessCount,
                validProcessSeconds: validProcessSeconds,
                discoveredProcessSeconds: discoveredProcessSeconds
            )
            let previousDisplay = working.displayByIdentity[identity]
            let displayAge = previousDisplay.map {
                observation.capturedAt - $0.sampleTime
            }
            let canPublishStale = displayAge.map {
                $0 >= 0 && $0 <= configuration.maximumGapSeconds
            } == true
            let allProcessesUnsupported = processIdentifiers.isEmpty == false
                && unsupportedProcessCount == processIdentifiers.count

            guard let generation = identity.generation else {
                candidates.append(EnergyImpactEntry(
                    identity: identity,
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    kind: app.kind,
                    currentPowerMicrowatts: allProcessesUnsupported
                        ? nil
                        : currentPowerMicrowatts,
                    sustainedPowerMicrowatts: nil,
                    rankingScore: nil,
                    trend: .steady,
                    coverage: currentCoverage,
                    status: .collecting,
                    observedWindowSeconds: observationDuration
                ))
                continue
            }

            var estimate: (
                fast: Double,
                sustained: Double?,
                score: Double?,
                trend: EnergyImpactTrend,
                coverage: Double,
                validProcessSeconds: TimeInterval,
                discoveredProcessSeconds: TimeInterval,
                observedWallSeconds: TimeInterval
            )?
            if observationDuration > 0,
               rootsRequiringFreshInterval.contains(app.processIdentifier) == false {
                var accumulator = working.accumulators[generation]
                    ?? EnergyImpactAccumulator(configuration: configuration)
                estimate = accumulator.observe(
                    sample: EnergyIntervalSample(
                        endTimeSeconds: observation.capturedAt,
                        durationSeconds: observationDuration,
                        contributions: contributions,
                        discoveredProcessSeconds: discoveredProcessSeconds
                    ),
                    rawPowerMicrowatts: currentPowerMicrowatts
                )
                working.accumulators[generation] = accumulator
            }

            if let estimate {
                let coverage = EnergyImpactCoverage(
                    discoveredProcessCount: processIdentifiers.count,
                    readableProcessCount: readableProcessCount,
                    validProcessSeconds: estimate.validProcessSeconds,
                    discoveredProcessSeconds: estimate.discoveredProcessSeconds
                )
                let status: EnergyImpactStatus
                if estimate.observedWallSeconds < 15 {
                    status = .collecting
                } else if estimate.coverage < 0.9 {
                    status = .partial
                } else {
                    status = .stable
                }
                let entry = EnergyImpactEntry(
                    identity: identity,
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    kind: app.kind,
                    currentPowerMicrowatts: estimate.fast,
                    sustainedPowerMicrowatts: estimate.sustained,
                    rankingScore: estimate.score,
                    trend: estimate.trend,
                    coverage: coverage,
                    status: status,
                    observedWindowSeconds: estimate.observedWallSeconds
                )
                working.displayByIdentity[identity] = EnergyImpactDisplayState(
                    entry: entry,
                    sampleTime: observation.capturedAt
                )
                candidates.append(entry)
            } else if allProcessesUnsupported {
                working.displayByIdentity.removeValue(forKey: identity)
                candidates.append(EnergyImpactEntry(
                    identity: identity,
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    kind: app.kind,
                    currentPowerMicrowatts: nil,
                    sustainedPowerMicrowatts: nil,
                    rankingScore: nil,
                    trend: .steady,
                    coverage: currentCoverage,
                    status: .unavailable,
                    observedWindowSeconds: observationDuration
                ))
            } else if canPublishStale {
                let displayed = previousDisplay!.entry
                candidates.append(EnergyImpactEntry(
                    identity: displayed.identity,
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    kind: app.kind,
                    currentPowerMicrowatts: displayed.currentPowerMicrowatts,
                    sustainedPowerMicrowatts: displayed.sustainedPowerMicrowatts,
                    rankingScore: nil,
                    trend: displayed.trend,
                    coverage: displayed.coverage,
                    status: .stale,
                    observedWindowSeconds: displayed.observedWindowSeconds
                ))
            } else {
                candidates.append(EnergyImpactEntry(
                    identity: identity,
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    kind: app.kind,
                    currentPowerMicrowatts: nil,
                    sustainedPowerMicrowatts: nil,
                    rankingScore: nil,
                    trend: .steady,
                    coverage: currentCoverage,
                    status: readableProcessCount > 0
                        ? .collecting
                        : .unavailable,
                    observedWindowSeconds: observationDuration
                ))
            }
        }

        let currentGenerations = Set(observation.apps.compactMap {
            working.currentIdentityByRootProcessIdentifier[$0.processIdentifier]?
                .generation
        })
        working.retainOnlyRootGenerations(currentGenerations)
        working.prune(at: observation.capturedAt, configuration: configuration)
        return candidates
    }

    private func canContinue(
        _ lease: EnergyImpactSamplingLease
    ) -> Bool {
        Task.isCancelled == false && activeLease == lease
    }
}

private struct EnergyImpactObservation: Sendable {
    let sequence: UInt64
    let capturedAt: TimeInterval
    let apps: [EnergyImpactAppSnapshot]
    let processSnapshots: [ProcessParentSnapshot]
    let owners: [pid_t: pid_t]
    let readingsByProcessIdentifier: [pid_t: ProcessEnergyReadResult]
}

private struct EnergyImpactSamplerState: Sendable {
    var baselines: [EnergyImpactProcessIdentity: ProcessEnergyBaseline] = [:]
    var identityByProcessIdentifier: [pid_t: EnergyImpactProcessIdentity] = [:]
    var currentIdentityByRootProcessIdentifier: [pid_t: EnergyImpactAppIdentity] = [:]
    var accumulators: [EnergyImpactProcessIdentity: EnergyImpactAccumulator] = [:]
    var displayByIdentity: [EnergyImpactAppIdentity: EnergyImpactDisplayState] = [:]
    var previousObservationTime: TimeInterval?
    var publicationState: EnergyImpactPublicationState
    var sequence: UInt64 = 0

    init(configuration: EnergyImpactConfiguration) {
        publicationState = EnergyImpactPublicationState(configuration: configuration)
    }

    mutating func breakContinuity() {
        baselines.removeAll()
        identityByProcessIdentifier.removeAll()
        currentIdentityByRootProcessIdentifier.removeAll()
        accumulators.removeAll()
        displayByIdentity.removeAll()
    }

    mutating func prune(
        at observationTime: TimeInterval,
        configuration: EnergyImpactConfiguration
    ) {
        let expiredIdentities = baselines.compactMap { identity, baseline in
            let age = observationTime - baseline.lastObservedAt
            return age > configuration.maximumGapSeconds ? identity : nil
        }
        for identity in expiredIdentities {
            if let appIdentity =
                currentIdentityByRootProcessIdentifier[identity.processIdentifier],
               appIdentity.generation == identity {
                removeBaseline(for: identity)
                removeEstimatedState(
                    rootProcessIdentifier: identity.processIdentifier
                )
                currentIdentityByRootProcessIdentifier.removeValue(
                    forKey: identity.processIdentifier
                )
            } else {
                removeBaseline(for: identity)
            }
        }

        displayByIdentity = displayByIdentity.filter { _, display in
            let age = observationTime - display.sampleTime
            return age >= 0 && age <= configuration.maximumGapSeconds
        }
        identityByProcessIdentifier = identityByProcessIdentifier.filter {
            baselines[$0.value] != nil
        }
        currentIdentityByRootProcessIdentifier =
            currentIdentityByRootProcessIdentifier.filter { _, identity in
                identity.generation.map { baselines[$0] != nil } == true
            }
        let currentGenerations = Set(
            currentIdentityByRootProcessIdentifier.values.compactMap(\.generation)
        )
        retainOnlyRootGenerations(currentGenerations)
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
            let affectedRoots = [
                baseline.ownerRootProcessIdentifier,
                owners[processIdentifier],
            ].compactMap { $0 }
            for rootProcessIdentifier in Set(affectedRoots) {
                removeEstimatedState(
                    rootProcessIdentifier: rootProcessIdentifier
                )
            }
            removeBaseline(for: identity)
        }
    }

    mutating func removeRootOwnedState(
        rootProcessIdentifier: pid_t
    ) {
        let ownedIdentities = baselines.compactMap { identity, baseline in
            baseline.ownerRootProcessIdentifier == rootProcessIdentifier
                ? identity
                : nil
        }
        for identity in ownedIdentities {
            removeBaseline(for: identity)
        }
        removeEstimatedState(rootProcessIdentifier: rootProcessIdentifier)
        currentIdentityByRootProcessIdentifier.removeValue(
            forKey: rootProcessIdentifier
        )
    }

    mutating func removeEstimatedState(
        rootProcessIdentifier: pid_t
    ) {
        let generations = currentIdentityByRootProcessIdentifier[
            rootProcessIdentifier
        ]?.generation.map { Set([$0]) } ?? []
        accumulators = accumulators.filter {
            generations.contains($0.key) == false
        }
        displayByIdentity = displayByIdentity.filter { identity, _ in
            identity.rootProcessIdentifier != rootProcessIdentifier
        }
    }

    mutating func retainOnlyRootGenerations(
        _ generations: Set<EnergyImpactProcessIdentity>
    ) {
        accumulators = accumulators.filter { generations.contains($0.key) }
        displayByIdentity = displayByIdentity.filter { identity, _ in
            identity.generation.map { generations.contains($0) } == true
        }
    }

    mutating func removeBaseline(for identity: EnergyImpactProcessIdentity) {
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
