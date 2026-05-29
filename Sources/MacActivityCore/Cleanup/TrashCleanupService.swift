import Foundation

public enum TrashScanResult: Equatable, Sendable {
    case clean
    case cleanable(bytes: UInt64, itemCount: Int)
    case failed(String)
}

public enum TrashCleanupResult: Equatable, Sendable {
    case cleaned(bytes: UInt64, itemCount: Int)
    case partial(bytes: UInt64, deletedCount: Int, failedCount: Int)
    case failed(String)
}

public protocol TrashFilesystem: Sendable {
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func allocatedSizeOfItem(at url: URL) throws -> UInt64
    func removeItem(at url: URL) throws
}

public struct LiveTrashFilesystem: TrashFilesystem {
    public init() {}

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ],
            options: []
        )
    }

    public func allocatedSizeOfItem(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ])
        var total = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))

        guard values.isDirectory == true else {
            return total
        }

        let children = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ],
            options: []
        )

        while let child = children?.nextObject() as? URL {
            let childValues = try? child.resourceValues(forKeys: [
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
            ])
            total += UInt64(max(0, childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0))
        }

        return total
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

public struct TrashCleanupService: Sendable {
    private let trashDirectory: URL
    private let filesystem: any TrashFilesystem

    public init(
        trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true),
        filesystem: any TrashFilesystem = LiveTrashFilesystem()
    ) {
        self.trashDirectory = trashDirectory
        self.filesystem = filesystem
    }

    public func scan() async -> TrashScanResult {
        let trashDirectory = self.trashDirectory
        let filesystem = self.filesystem

        return await Task.detached(priority: .utility) {
            Self.scan(trashDirectory: trashDirectory, filesystem: filesystem)
        }.value
    }

    public func clean() async -> TrashCleanupResult {
        let trashDirectory = self.trashDirectory
        let filesystem = self.filesystem

        return await Task.detached(priority: .utility) {
            Self.clean(trashDirectory: trashDirectory, filesystem: filesystem)
        }.value
    }

    private static func scan(trashDirectory: URL, filesystem: any TrashFilesystem) -> TrashScanResult {
        do {
            let children = try filesystem.contentsOfDirectory(at: trashDirectory)
            guard !children.isEmpty else {
                return .clean
            }

            let totalBytes = children.reduce(UInt64(0)) { total, child in
                total + ((try? filesystem.allocatedSizeOfItem(at: child)) ?? 0)
            }

            return .cleanable(bytes: totalBytes, itemCount: children.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func clean(trashDirectory: URL, filesystem: any TrashFilesystem) -> TrashCleanupResult {
        do {
            let children = try filesystem.contentsOfDirectory(at: trashDirectory)
            var deletedBytes: UInt64 = 0
            var deletedCount = 0
            var failedCount = 0

            for child in children {
                let allocatedSize = (try? filesystem.allocatedSizeOfItem(at: child)) ?? 0
                do {
                    try filesystem.removeItem(at: child)
                    deletedBytes += allocatedSize
                    deletedCount += 1
                } catch {
                    failedCount += 1
                }
            }

            if failedCount == 0 {
                return .cleaned(bytes: deletedBytes, itemCount: deletedCount)
            }

            if deletedCount == 0 {
                return .failed("Unable to delete Trash items.")
            }

            return .partial(bytes: deletedBytes, deletedCount: deletedCount, failedCount: failedCount)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
