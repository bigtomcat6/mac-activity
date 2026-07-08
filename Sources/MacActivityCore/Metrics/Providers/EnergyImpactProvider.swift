import AppKit
import Darwin
import Foundation

public struct EnergyImpactEntry: Identifiable, Equatable, Sendable {
    public let id: pid_t
    public let processIdentifier: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let impact: Double
    public let isReadable: Bool

    public init(
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        bundleURL: URL?,
        impact: Double,
        isReadable: Bool
    ) {
        self.id = processIdentifier
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.impact = impact
        self.isReadable = isReadable
    }

    public var formattedImpact: String {
        guard isReadable else { return "Unavailable" }
        return String(format: "%.1f", impact)
    }
}

public struct EnergyImpactAppSnapshot: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?

    public init(
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        bundleURL: URL?
    ) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
    }
}

public struct ProcessEnergyReading: Equatable, Sendable {
    public let energyNanojoules: UInt64

    public init(energyNanojoules: UInt64) {
        self.energyNanojoules = energyNanojoules
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
        return ProcessEnergyReading(energyNanojoules: info.ri_energy_nj)
    }
}

@MainActor
public final class EnergyImpactService {
    private let reader: any ProcessEnergyReadingProvider
    private let appSnapshotProvider: () -> [EnergyImpactAppSnapshot]
    private var previousReadings: [pid_t: ProcessEnergyReading] = [:]

    public init(
        workspace: NSWorkspace = .shared,
        reader: any ProcessEnergyReadingProvider = SystemProcessEnergyReader(),
        appSnapshotProvider: (() -> [EnergyImpactAppSnapshot])? = nil
    ) {
        self.reader = reader
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
        var nextReadings: [pid_t: ProcessEnergyReading] = [:]
        let entries = apps.map { app -> EnergyImpactEntry in
            guard let current = reader.reading(for: app.processIdentifier) else {
                return EnergyImpactEntry(
                    processIdentifier: app.processIdentifier,
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    impact: 0,
                    isReadable: false
                )
            }
            nextReadings[app.processIdentifier] = current
            let impact: Double
            if let previous = previousReadings[app.processIdentifier],
               current.energyNanojoules >= previous.energyNanojoules {
                impact = Double(current.energyNanojoules - previous.energyNanojoules) / 1_000.0
            } else {
                impact = 0
            }

            return EnergyImpactEntry(
                processIdentifier: app.processIdentifier,
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                impact: impact,
                isReadable: true
            )
        }
        previousReadings = nextReadings
        return Self.sortedByImpact(entries, limit: limit)
    }

    public nonisolated static func sortedByImpact(_ entries: [EnergyImpactEntry], limit: Int) -> [EnergyImpactEntry] {
        entries
            .sorted { lhs, rhs in
                if lhs.impact == rhs.impact {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.impact > rhs.impact
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
