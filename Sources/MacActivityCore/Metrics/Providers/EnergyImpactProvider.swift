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
public protocol EnergyImpactAppCataloging: AnyObject {
    func snapshots(scope: EnergyImpactAppScope) -> [EnergyImpactAppSnapshot]
}

@MainActor
public final class SystemEnergyImpactAppCatalog: EnergyImpactAppCataloging {
    private let snapshotProvider: @MainActor () -> [EnergyImpactAppSnapshot]
    private let nowSeconds: @MainActor () -> TimeInterval
    private let refreshIntervalSeconds: TimeInterval
    private var cachedSnapshots: [EnergyImpactAppSnapshot]?
    private var lastRefreshTime: TimeInterval?

    public init(workspace: NSWorkspace = .shared) {
        snapshotProvider = {
            Self.appSnapshots(from: workspace.runningApplications)
        }
        nowSeconds = { ProcessInfo.processInfo.systemUptime }
        refreshIntervalSeconds = EnergyImpactConfiguration.production.publicationIntervalSeconds
    }

    init(
        snapshotProvider: @escaping @MainActor () -> [EnergyImpactAppSnapshot],
        nowSeconds: @escaping @MainActor () -> TimeInterval,
        refreshIntervalSeconds: TimeInterval
    ) {
        self.snapshotProvider = snapshotProvider
        self.nowSeconds = nowSeconds
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }

    public func snapshots(scope: EnergyImpactAppScope) -> [EnergyImpactAppSnapshot] {
        let now = nowSeconds()
        if shouldRefresh(at: now) {
            cachedSnapshots = snapshotProvider()
            lastRefreshTime = now
        }
        let snapshots = cachedSnapshots ?? []
        guard scope == .regularOnly else { return snapshots }
        return snapshots.filter { $0.kind == .regular }
    }

    private func shouldRefresh(at now: TimeInterval) -> Bool {
        guard cachedSnapshots != nil,
              let lastRefreshTime,
              refreshIntervalSeconds > 0,
              now.isFinite,
              lastRefreshTime.isFinite else {
            return true
        }
        let age = now - lastRefreshTime
        return age < 0 || age >= refreshIntervalSeconds
    }

    private static func appSnapshots(
        from runningApplications: [NSRunningApplication]
    ) -> [EnergyImpactAppSnapshot] {
        var seen = Set<pid_t>()
        return runningApplications
            .filter {
                $0.processIdentifier > 0
                    && ($0.activationPolicy == .regular || $0.activationPolicy == .accessory)
            }
            .filter { seen.insert($0.processIdentifier).inserted }
            .map {
                EnergyImpactAppSnapshot(
                    processIdentifier: $0.processIdentifier,
                    name: $0.localizedName
                        ?? $0.bundleIdentifier
                        ?? "Process \($0.processIdentifier)",
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL,
                    kind: $0.activationPolicy == .accessory ? .accessory : .regular
                )
            }
    }
}

@MainActor
public final class EnergyImpactService {
    private let catalog: any EnergyImpactAppCataloging
    private let sampler: any EnergyImpactSampling

    public init(
        catalog: any EnergyImpactAppCataloging = SystemEnergyImpactAppCatalog(),
        sampler: any EnergyImpactSampling = EnergyImpactSampler()
    ) {
        self.catalog = catalog
        self.sampler = sampler
    }

    public func beginSession() async -> EnergyImpactSessionID {
        await sampler.beginSession()
    }

    public func sample(
        sessionID: EnergyImpactSessionID,
        limit: Int,
        scope: EnergyImpactAppScope = .regularOnly,
        publicationBoundary: Bool
    ) async -> [EnergyImpactEntry]? {
        let apps = catalog.snapshots(scope: scope)
        return await sampler.sample(
            sessionID: sessionID,
            apps: apps,
            limit: limit,
            publicationBoundary: publicationBoundary
        )
    }

    public func endSession(_ sessionID: EnergyImpactSessionID) async {
        await sampler.endSession(sessionID)
    }
}
