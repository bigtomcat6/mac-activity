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

struct EnergyImpactCatalogCandidate {
    let processIdentifier: pid_t
    let activationPolicy: NSApplication.ActivationPolicy
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
}

@MainActor
final class SystemEnergyImpactAppCatalog: EnergyImpactAppCataloging {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    static func appSnapshots(
        from candidates: [EnergyImpactCatalogCandidate],
        scope: EnergyImpactAppScope
    ) -> [EnergyImpactAppSnapshot] {
        var seen = Set<pid_t>()
        return candidates.compactMap { candidate in
            guard candidate.processIdentifier > 0,
                  seen.insert(candidate.processIdentifier).inserted else {
                return nil
            }
            let kind: EnergyImpactAppKind
            switch candidate.activationPolicy {
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
                processIdentifier: candidate.processIdentifier,
                name: candidate.name,
                bundleIdentifier: candidate.bundleIdentifier,
                bundleURL: candidate.bundleURL,
                kind: kind
            )
        }
    }

    func snapshots(
        scope: EnergyImpactAppScope
    ) -> [EnergyImpactAppSnapshot] {
        Self.appSnapshots(
            from: workspace.runningApplications.map { application in
                EnergyImpactCatalogCandidate(
                    processIdentifier: application.processIdentifier,
                    activationPolicy: application.activationPolicy,
                    name: application.localizedName
                        ?? application.bundleIdentifier
                        ?? "Process \(application.processIdentifier)",
                    bundleIdentifier: application.bundleIdentifier,
                    bundleURL: application.bundleURL
                )
            },
            scope: scope
        )
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
