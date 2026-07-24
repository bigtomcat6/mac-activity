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

    public init(
        energyNanojoules: UInt64,
        processStartAbsoluteTime: UInt64 = 0
    ) {
        self.energyNanojoules = energyNanojoules
        self.processStartAbsoluteTime = processStartAbsoluteTime
    }
}

public protocol ProcessEnergyReadingProvider: Sendable {
    func reading(for processIdentifier: pid_t) -> ProcessEnergyReading?
}

public struct SystemProcessEnergyReader: ProcessEnergyReadingProvider {
    public init() {}

    public func reading(for processIdentifier: pid_t) -> ProcessEnergyReading? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V6, reboundPointer)
            }
        }
        guard result == 0 else { return nil }
        return ProcessEnergyReading(
            energyNanojoules: info.ri_energy_nj,
            processStartAbsoluteTime: info.ri_proc_start_abstime
        )
    }
}

@MainActor
public final class EnergyImpactService {
    private let reader: any ProcessEnergyReadingProvider
    private let processSnapshotReader: any ProcessMemorySnapshotReading
    private let appSnapshotProvider: () -> [EnergyImpactAppSnapshot]
    private let now: () -> Date
    private var previousReadings: [pid_t: TimedProcessEnergyReading] = [:]

    public init(
        workspace: NSWorkspace = .shared,
        reader: any ProcessEnergyReadingProvider = SystemProcessEnergyReader(),
        processSnapshotReader: any ProcessMemorySnapshotReading = SystemProcessMemorySnapshotReader(),
        appSnapshotProvider: (() -> [EnergyImpactAppSnapshot])? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.reader = reader
        self.processSnapshotReader = processSnapshotReader
        self.now = now
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
        let sampleTime = now().timeIntervalSinceReferenceDate
        let processIdentifiersByRoot = Self.processIdentifiersByRoot(
            rootProcessIdentifiers: apps.map(\.processIdentifier),
            snapshots: processSnapshotReader.snapshots()
        )
        var nextReadings: [pid_t: TimedProcessEnergyReading] = [:]
        let entries = apps.map { app -> EnergyImpactEntry in
            let processIdentifiers = processIdentifiersByRoot[app.processIdentifier] ?? [app.processIdentifier]
            var rootProcessStartAbsoluteTime: UInt64?
            var totalPowerMicrowatts = 0.0
            var readableProcessCount = 0
            var validDeltaCount = 0

            for processIdentifier in processIdentifiers {
                guard let current = reader.reading(for: processIdentifier) else { continue }
                if processIdentifier == app.processIdentifier {
                    rootProcessStartAbsoluteTime = current.processStartAbsoluteTime
                }
                readableProcessCount += 1
                nextReadings[processIdentifier] = TimedProcessEnergyReading(
                    reading: current,
                    sampleTime: sampleTime
                )
                if let previous = previousReadings[processIdentifier],
                   let impactRate = Self.impactRate(from: previous, to: current, sampleTime: sampleTime) {
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

    public nonisolated static func processIdentifiersByRoot(
        rootProcessIdentifiers: [pid_t],
        snapshots: [ProcessMemorySnapshot]
    ) -> [pid_t: [pid_t]] {
        let childrenByParent = Dictionary(grouping: snapshots, by: \.parentProcessIdentifier)

        return Dictionary(uniqueKeysWithValues: rootProcessIdentifiers.map { rootProcessIdentifier in
            var identifiers = [rootProcessIdentifier]
            var visited = Set<pid_t>([rootProcessIdentifier])
            var stack = childrenByParent[rootProcessIdentifier] ?? []

            while let child = stack.popLast() {
                guard visited.insert(child.processIdentifier).inserted else { continue }
                identifiers.append(child.processIdentifier)
                stack.append(contentsOf: childrenByParent[child.processIdentifier] ?? [])
            }

            return (rootProcessIdentifier, identifiers)
        })
    }

    private nonisolated static func impactRate(
        from previous: TimedProcessEnergyReading,
        to current: ProcessEnergyReading,
        sampleTime: TimeInterval
    ) -> Double? {
        guard current.processStartAbsoluteTime == previous.reading.processStartAbsoluteTime,
              current.energyNanojoules >= previous.reading.energyNanojoules else {
            return nil
        }
        let elapsedSeconds = sampleTime - previous.sampleTime
        guard elapsedSeconds > 0 else { return nil }
        let deltaMicrojoules = Double(current.energyNanojoules - previous.reading.energyNanojoules) / 1_000.0
        return deltaMicrojoules / elapsedSeconds
    }
}

private struct TimedProcessEnergyReading: Sendable {
    let reading: ProcessEnergyReading
    let sampleTime: TimeInterval
}
