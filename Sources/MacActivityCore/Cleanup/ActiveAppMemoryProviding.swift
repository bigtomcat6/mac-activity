import Foundation

@MainActor
public protocol ActiveAppMemoryProviding: AnyObject {
    func topApps(limit: Int) -> [ActiveAppMemoryEntry]
    func requestTermination(processIdentifier: pid_t) -> ActiveAppTerminationResult
}

extension ActiveAppMemoryService: ActiveAppMemoryProviding {}
