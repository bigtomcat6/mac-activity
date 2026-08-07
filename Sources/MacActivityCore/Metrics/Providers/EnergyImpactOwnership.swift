import Darwin
import Foundation

public enum EnergyImpactOwnership {
    public static func nearestRootOwners(
        rootProcessIdentifiers: [pid_t],
        snapshots: [ProcessParentSnapshot]
    ) -> [pid_t: pid_t] {
        let roots = Set(rootProcessIdentifiers)
        let parentByProcess = Dictionary(
            snapshots.map { ($0.processIdentifier, $0.parentProcessIdentifier) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = Set(parentByProcess.keys).union(roots)
        var resolved: [pid_t: pid_t] = [:]

        for candidate in candidates {
            if let owner = nearestRoot(
                for: candidate,
                roots: roots,
                parentByProcess: parentByProcess
            ) {
                resolved[candidate] = owner
            }
        }
        return resolved
    }

    private static func nearestRoot(
        for processIdentifier: pid_t,
        roots: Set<pid_t>,
        parentByProcess: [pid_t: pid_t]
    ) -> pid_t? {
        var current = processIdentifier
        var visited = Set<pid_t>()

        while visited.insert(current).inserted {
            if roots.contains(current) { return current }
            guard let parent = parentByProcess[current], parent > 0 else { return nil }
            current = parent
        }
        return nil
    }
}
