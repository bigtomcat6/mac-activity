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

@MainActor
protocol EnergyImpactAppCataloging: AnyObject {
    func snapshots(
        scope: EnergyImpactAppScope
    ) -> [EnergyImpactAppSnapshot]
}

@MainActor
private final class SystemEnergyImpactAppCatalog: EnergyImpactAppCataloging {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func snapshots(
        scope: EnergyImpactAppScope
    ) -> [EnergyImpactAppSnapshot] {
        var seenProcessIdentifiers = Set<pid_t>()
        return workspace.runningApplications.compactMap { application in
            let processIdentifier = application.processIdentifier
            guard processIdentifier > 0,
                  seenProcessIdentifiers.insert(processIdentifier).inserted else {
                return nil
            }

            let kind: EnergyImpactAppKind
            switch application.activationPolicy {
            case .regular:
                kind = .regular
            case .accessory where scope == .regularAndAccessory:
                kind = .accessory
            case .accessory, .prohibited:
                return nil
            @unknown default:
                return nil
            }

            return EnergyImpactAppSnapshot(
                processIdentifier: processIdentifier,
                name: application.localizedName
                    ?? application.bundleIdentifier
                    ?? "Process \(processIdentifier)",
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                kind: kind
            )
        }
    }
}

@MainActor
public final class EnergyImpactService {
    private let catalog: any EnergyImpactAppCataloging
    private let sampler: any EnergyImpactSampling
    private var nextRequestGeneration: UInt64 = 0

    public init() {
        catalog = SystemEnergyImpactAppCatalog()
        sampler = EnergyImpactSampler()
    }

    init(
        catalog: any EnergyImpactAppCataloging,
        sampler: any EnergyImpactSampling
    ) {
        self.catalog = catalog
        self.sampler = sampler
    }

    public func beginSession() async -> EnergyImpactSamplingLease? {
        guard nextRequestGeneration < UInt64.max else { return nil }
        nextRequestGeneration += 1
        let request = EnergyImpactSessionRequest(
            generation: nextRequestGeneration
        )
        return await sampler.beginSession(request)
    }

    public func observe(
        lease: EnergyImpactSamplingLease,
        limit: Int,
        scope: EnergyImpactAppScope = .regularOnly
    ) async -> [EnergyImpactEntry]? {
        let apps = catalog.snapshots(scope: scope)
        return await sampler.observe(
            lease: lease,
            apps: apps,
            limit: limit
        )
    }

    public func endSession(
        _ lease: EnergyImpactSamplingLease
    ) async {
        await sampler.endSession(lease)
    }
}
