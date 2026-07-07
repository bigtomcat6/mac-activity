import Foundation

@MainActor
public protocol ActiveAppMemoryProviding: AnyObject {
    func topApps(limit: Int) -> [ActiveAppMemoryEntry]
    func requestTermination(_ app: ActiveAppMemoryEntry) -> ActiveAppTerminationResult
}

extension ActiveAppMemoryService: ActiveAppMemoryProviding {}
