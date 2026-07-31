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
    private var previousReadings: [EnergyImpactProcessIdentity: TimedProcessEnergyReading] = [:]

    public init(
        workspace: NSWorkspace = .shared,
        reader: any ProcessEnergyReadingProvider = SystemProcessEnergyReader(),
        processSnapshotReader: any ProcessParentSnapshotReading = SystemProcessParentSnapshotReader(),
        appSnapshotProvider: (() -> [EnergyImpactAppSnapshot])? = nil,
        clock: any EnergyImpactClock = SystemEnergyImpactClock()
    ) {
        self.reader = reader
        self.processSnapshotReader = processSnapshotReader
        self.clock = clock
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
        let apps = appSnapshotProvider()
        let sampleTime = clock.nowSeconds()
        let owners = EnergyImpactOwnership.nearestRootOwners(
            rootProcessIdentifiers: apps.map(\.processIdentifier),
            snapshots: processSnapshotReader.snapshots()
        )
        let processIdentifiersByRoot = Dictionary(
            grouping: owners.keys,
            by: { owners[$0]! }
        )
        var nextReadings: [EnergyImpactProcessIdentity: TimedProcessEnergyReading] = [:]
        let entries = apps.map { app -> EnergyImpactEntry in
            let processIdentifiers = processIdentifiersByRoot[app.processIdentifier] ?? [app.processIdentifier]
            var rootProcessStartAbsoluteTime: UInt64?
            var totalPowerMicrowatts = 0.0
            var readableProcessCount = 0
            var validDeltaCount = 0

            for processIdentifier in processIdentifiers {
                guard case let .success(current) = reader.reading(for: processIdentifier) else { continue }
                if processIdentifier == app.processIdentifier {
                    rootProcessStartAbsoluteTime = current.processStartAbsoluteTime
                }
                readableProcessCount += 1
                let identity = EnergyImpactProcessIdentity(
                    processIdentifier: processIdentifier,
                    processStartAbsoluteTime: current.processStartAbsoluteTime
                )
                nextReadings[identity] = TimedProcessEnergyReading(
                    reading: current,
                    sampleTime: sampleTime
                )
                if let previous = previousReadings[identity],
                   let impactRate = Self.impactRate(
                       from: previous,
                       to: current,
                       sampleTime: sampleTime,
                       maximumGapSeconds: EnergyImpactConfiguration.production.maximumGapSeconds
                   ) {
                    totalPowerMicrowatts += impactRate
                    validDeltaCount += 1
                }
            }

            let identity = EnergyImpactAppIdentity(
                rootProcessIdentifier: app.processIdentifier,
                rootProcessStartAbsoluteTime: rootProcessStartAbsoluteTime
            )
            let coverage = EnergyImpactCoverage(
                discoveredProcessCount: processIdentifiers.count,
                readableProcessCount: readableProcessCount,
                validProcessSeconds: TimeInterval(validDeltaCount),
                discoveredProcessSeconds: TimeInterval(processIdentifiers.count)
            )
            let status: EnergyImpactStatus = if readableProcessCount == 0 {
                .unavailable
            } else if validDeltaCount == 0 {
                .collecting
            } else if validDeltaCount < processIdentifiers.count {
                .partial
            } else {
                .stable
            }
            let currentPower = validDeltaCount == 0 ? nil : totalPowerMicrowatts

            return EnergyImpactEntry(
                identity: identity,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                kind: app.kind,
                currentPowerMicrowatts: currentPower,
                sustainedPowerMicrowatts: nil,
                rankingScore: currentPower,
                trend: .steady,
                coverage: coverage,
                status: status
            )
        }
        previousReadings = nextReadings
        return Self.sortedByImpact(entries, limit: limit)
    }

    public nonisolated static func sortedByImpact(
        _ entries: [EnergyImpactEntry],
        limit: Int
    ) -> [EnergyImpactEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.rankingScore, rhs.rankingScore) {
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

    private nonisolated static func impactRate(
        from previous: TimedProcessEnergyReading,
        to current: ProcessEnergyReading,
        sampleTime: TimeInterval,
        maximumGapSeconds: TimeInterval
    ) -> Double? {
        guard current.processStartAbsoluteTime == previous.reading.processStartAbsoluteTime,
              current.energyNanojoules >= previous.reading.energyNanojoules else {
            return nil
        }
        let elapsedSeconds = sampleTime - previous.sampleTime
        guard elapsedSeconds > 0, elapsedSeconds <= maximumGapSeconds else { return nil }
        let deltaMicrojoules = Double(current.energyNanojoules - previous.reading.energyNanojoules) / 1_000.0
        return deltaMicrojoules / elapsedSeconds
    }
}

private struct TimedProcessEnergyReading: Sendable {
    let reading: ProcessEnergyReading
    let sampleTime: TimeInterval
}
