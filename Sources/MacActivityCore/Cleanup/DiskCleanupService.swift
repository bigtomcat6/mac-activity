import Foundation

public enum DiskCleanupCategoryKind: String, CaseIterable, Codable, Sendable {
    case trash
    case userCaches
    case userLogs
}

public enum DiskCleanupDeletionMode: String, Codable, Sendable {
    case deleteImmediately
    case moveToTrash
}

public struct DiskCleanupRoots: Equatable, Sendable {
    public let trashDirectory: URL
    public let userCachesDirectory: URL
    public let userLogsDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(
            trashDirectory: homeDirectory.appendingPathComponent(".Trash", isDirectory: true),
            userCachesDirectory: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true),
            userLogsDirectory: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
        )
    }

    public init(
        trashDirectory: URL,
        userCachesDirectory: URL,
        userLogsDirectory: URL
    ) {
        self.trashDirectory = trashDirectory
        self.userCachesDirectory = userCachesDirectory
        self.userLogsDirectory = userLogsDirectory
    }

    public func url(for kind: DiskCleanupCategoryKind) -> URL {
        switch kind {
        case .trash:
            return trashDirectory
        case .userCaches:
            return userCachesDirectory
        case .userLogs:
            return userLogsDirectory
        }
    }
}

public struct DiskCleanupItemMetadata: Equatable, Sendable {
    public let allocatedBytes: UInt64
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let contentModificationDate: Date?

    public init(
        allocatedBytes: UInt64,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        contentModificationDate: Date?
    ) {
        self.allocatedBytes = allocatedBytes
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.contentModificationDate = contentModificationDate
    }
}

public protocol DiskCleanupFilesystem: Sendable {
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func itemMetadata(at url: URL) throws -> DiskCleanupItemMetadata
    func removeItem(at url: URL) throws
    func trashItem(at url: URL) throws
}

public struct LiveDiskCleanupFilesystem: DiskCleanupFilesystem {
    public init() {}

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Self.resourceKeys,
            options: []
        )
    }

    public func itemMetadata(at url: URL) throws -> DiskCleanupItemMetadata {
        let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
        return DiskCleanupItemMetadata(
            allocatedBytes: UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)),
            isDirectory: values.isDirectory == true,
            isSymbolicLink: values.isSymbolicLink == true,
            contentModificationDate: values.contentModificationDate
        )
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func trashItem(at url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
    ]
}

public struct DiskCleanupCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let displayPath: String
    public let kind: DiskCleanupCategoryKind
    public let allocatedBytes: UInt64
    public let deletionMode: DiskCleanupDeletionMode
    public let isDefaultSelected: Bool
    public let reason: String

    public init(
        url: URL,
        kind: DiskCleanupCategoryKind,
        allocatedBytes: UInt64,
        deletionMode: DiskCleanupDeletionMode,
        isDefaultSelected: Bool = true,
        reason: String
    ) {
        self.id = "\(kind.rawValue):\(url.path)"
        self.url = url
        self.displayPath = url.path
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.deletionMode = deletionMode
        self.isDefaultSelected = isDefaultSelected
        self.reason = reason
    }
}

public struct DiskCleanupCategorySummary: Identifiable, Equatable, Sendable {
    public var id: DiskCleanupCategoryKind { kind }

    public let kind: DiskCleanupCategoryKind
    public let titleKey: String
    public let totalBytes: UInt64
    public let selectedBytes: UInt64
    public let itemCount: Int
    public let selectedItemCount: Int
    public let accessIssueCount: Int

    public init(
        kind: DiskCleanupCategoryKind,
        titleKey: String,
        totalBytes: UInt64,
        selectedBytes: UInt64,
        itemCount: Int,
        selectedItemCount: Int,
        accessIssueCount: Int
    ) {
        self.kind = kind
        self.titleKey = titleKey
        self.totalBytes = totalBytes
        self.selectedBytes = selectedBytes
        self.itemCount = itemCount
        self.selectedItemCount = selectedItemCount
        self.accessIssueCount = accessIssueCount
    }
}

public struct DiskCleanupAccessIssue: Equatable, Sendable {
    public let kind: DiskCleanupCategoryKind
    public let url: URL
    public let message: String

    public init(kind: DiskCleanupCategoryKind, url: URL, message: String) {
        self.kind = kind
        self.url = url
        self.message = message
    }
}

public struct DiskCleanupSummary: Equatable, Sendable {
    public let totalBytes: UInt64
    public let selectedBytes: UInt64
    public let itemCount: Int
    public let selectedItemCount: Int
    public let accessIssueCount: Int
    public let categories: [DiskCleanupCategorySummary]
    public let candidates: [DiskCleanupCandidate]
    public let accessIssues: [DiskCleanupAccessIssue]

    public init(
        totalBytes: UInt64,
        selectedBytes: UInt64,
        itemCount: Int,
        selectedItemCount: Int,
        accessIssueCount: Int,
        categories: [DiskCleanupCategorySummary],
        candidates: [DiskCleanupCandidate],
        accessIssues: [DiskCleanupAccessIssue]
    ) {
        self.totalBytes = totalBytes
        self.selectedBytes = selectedBytes
        self.itemCount = itemCount
        self.selectedItemCount = selectedItemCount
        self.accessIssueCount = accessIssueCount
        self.categories = categories
        self.candidates = candidates
        self.accessIssues = accessIssues
    }
}

public enum DiskCleanupScanResult: Equatable, Sendable {
    case clean
    case cleanable(summary: DiskCleanupSummary)
    case failed(String)
}

public enum DiskCleanupResult: Equatable, Sendable {
    case cleaned(bytes: UInt64, itemCount: Int)
    case partial(bytes: UInt64, deletedCount: Int, failedCount: Int, remainingBytes: UInt64?)
    case failed(String)
}

public struct DiskCleanupService: Sendable {
    private let roots: DiskCleanupRoots
    private let filesystem: any DiskCleanupFilesystem

    public init(
        roots: DiskCleanupRoots = DiskCleanupRoots(),
        filesystem: any DiskCleanupFilesystem = LiveDiskCleanupFilesystem()
    ) {
        self.roots = roots
        self.filesystem = filesystem
    }

    public func scan(
        categories: [DiskCleanupCategoryKind] = DiskCleanupCategoryKind.allCases,
        now: Date = Date()
    ) async -> DiskCleanupScanResult {
        let roots = self.roots
        let filesystem = self.filesystem

        return await Task.detached(priority: .utility) {
            Self.scan(categories: categories, now: now, roots: roots, filesystem: filesystem)
        }.value
    }

    public func clean(
        categories: [DiskCleanupCategoryKind] = DiskCleanupCategoryKind.allCases,
        now: Date = Date()
    ) async -> DiskCleanupResult {
        let roots = self.roots
        let filesystem = self.filesystem

        return await Task.detached(priority: .utility) {
            Self.clean(categories: categories, now: now, roots: roots, filesystem: filesystem)
        }.value
    }

    private static func scan(
        categories: [DiskCleanupCategoryKind],
        now: Date,
        roots: DiskCleanupRoots,
        filesystem: any DiskCleanupFilesystem
    ) -> DiskCleanupScanResult {
        var categorySummaries: [DiskCleanupCategorySummary] = []
        var candidates: [DiskCleanupCandidate] = []
        var accessIssues: [DiskCleanupAccessIssue] = []

        for kind in categories {
            let category = scanCategory(kind, now: now, roots: roots, filesystem: filesystem)
            accessIssues.append(contentsOf: category.accessIssues)
            candidates.append(contentsOf: category.candidates)

            guard category.candidates.isEmpty == false else { continue }
            categorySummaries.append(summary(for: kind, candidates: category.candidates, accessIssueCount: category.accessIssues.count))
        }

        guard candidates.isEmpty == false else {
            if let issue = accessIssues.first {
                return .failed(issue.message)
            }
            return .clean
        }

        let totalBytes = candidates.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
        let selectedCandidates = candidates.filter(\.isDefaultSelected)
        let selectedBytes = selectedCandidates.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
        return .cleanable(
            summary: DiskCleanupSummary(
                totalBytes: totalBytes,
                selectedBytes: selectedBytes,
                itemCount: candidates.count,
                selectedItemCount: selectedCandidates.count,
                accessIssueCount: accessIssues.count,
                categories: categorySummaries,
                candidates: selectedCandidates,
                accessIssues: accessIssues
            )
        )
    }

    private static func clean(
        categories: [DiskCleanupCategoryKind],
        now: Date,
        roots: DiskCleanupRoots,
        filesystem: any DiskCleanupFilesystem
    ) -> DiskCleanupResult {
        let scanResult = scan(categories: categories, now: now, roots: roots, filesystem: filesystem)
        let summary: DiskCleanupSummary
        switch scanResult {
        case .clean:
            return .cleaned(bytes: 0, itemCount: 0)
        case .cleanable(let cleanableSummary):
            summary = cleanableSummary
        case .failed(let message):
            return .failed(message)
        }

        var deletedBytes: UInt64 = 0
        var deletedCount = 0
        var failedCount = 0
        var remainingBytes: UInt64 = 0

        for candidate in summary.candidates {
            guard isSafeToDelete(candidate, roots: roots, filesystem: filesystem) else {
                failedCount += 1
                remainingBytes += candidate.allocatedBytes
                continue
            }

            do {
                switch candidate.deletionMode {
                case .deleteImmediately:
                    try filesystem.removeItem(at: candidate.url)
                case .moveToTrash:
                    try filesystem.trashItem(at: candidate.url)
                }
                deletedBytes += candidate.allocatedBytes
                deletedCount += 1
            } catch {
                failedCount += 1
                remainingBytes += candidate.allocatedBytes
            }
        }

        if failedCount == 0 {
            return .cleaned(bytes: deletedBytes, itemCount: deletedCount)
        }

        if deletedCount == 0 {
            return .failed("Unable to delete selected disk cleanup items.")
        }

        return .partial(
            bytes: deletedBytes,
            deletedCount: deletedCount,
            failedCount: failedCount,
            remainingBytes: remainingBytes
        )
    }

    private static func scanCategory(
        _ kind: DiskCleanupCategoryKind,
        now: Date,
        roots: DiskCleanupRoots,
        filesystem: any DiskCleanupFilesystem
    ) -> CategoryScan {
        let root = roots.url(for: kind)
        switch kind {
        case .trash:
            return scanTrash(root: root, filesystem: filesystem)
        case .userCaches:
            return scanUserCaches(root: root, now: now, filesystem: filesystem)
        case .userLogs:
            return scanUserLogs(root: root, now: now, filesystem: filesystem)
        }
    }

    private static func scanTrash(
        root: URL,
        filesystem: any DiskCleanupFilesystem
    ) -> CategoryScan {
        do {
            let children = try filesystem.contentsOfDirectory(at: root)
            let candidates = children.compactMap { child -> DiskCleanupCandidate? in
                guard let size = allocatedSize(of: child, filesystem: filesystem) else { return nil }
                guard size > 0 else { return nil }
                return DiskCleanupCandidate(
                    url: child,
                    kind: .trash,
                    allocatedBytes: size,
                    deletionMode: .deleteImmediately,
                    reason: "trash"
                )
            }
            return CategoryScan(candidates: candidates)
        } catch {
            return CategoryScan(accessIssues: [DiskCleanupAccessIssue(kind: .trash, url: root, message: error.localizedDescription)])
        }
    }

    private static func scanUserCaches(
        root: URL,
        now: Date,
        filesystem: any DiskCleanupFilesystem
    ) -> CategoryScan {
        collectCandidates(
            root: root,
            kind: .userCaches,
            now: now,
            filesystem: filesystem
        ) { url, metadata in
            guard isOldEnough(metadata, now: now) else { return false }
            return isExcludedCachePath(url, root: root) == false
        }
    }

    private static func scanUserLogs(
        root: URL,
        now: Date,
        filesystem: any DiskCleanupFilesystem
    ) -> CategoryScan {
        collectCandidates(
            root: root,
            kind: .userLogs,
            now: now,
            filesystem: filesystem
        ) { url, metadata in
            guard isOldEnough(metadata, now: now) else { return false }
            return isLogFileName(url.lastPathComponent)
        }
    }

    private static func collectCandidates(
        root: URL,
        kind: DiskCleanupCategoryKind,
        now: Date,
        filesystem: any DiskCleanupFilesystem,
        shouldIncludeFile: (URL, DiskCleanupItemMetadata) -> Bool
    ) -> CategoryScan {
        var candidates: [DiskCleanupCandidate] = []
        var accessIssues: [DiskCleanupAccessIssue] = []

        func walk(_ directory: URL) {
            let children: [URL]
            do {
                children = try filesystem.contentsOfDirectory(at: directory)
            } catch {
                accessIssues.append(DiskCleanupAccessIssue(kind: kind, url: directory, message: error.localizedDescription))
                return
            }

            for child in children {
                if kind == .userCaches, isExcludedCachePath(child, root: root) {
                    continue
                }

                guard let metadata = try? filesystem.itemMetadata(at: child) else {
                    accessIssues.append(DiskCleanupAccessIssue(kind: kind, url: child, message: "Unable to read file metadata."))
                    continue
                }

                guard metadata.isSymbolicLink == false else { continue }

                if metadata.isDirectory {
                    walk(child)
                    continue
                }

                guard metadata.allocatedBytes > 0, shouldIncludeFile(child, metadata) else { continue }
                candidates.append(
                    DiskCleanupCandidate(
                        url: child,
                        kind: kind,
                        allocatedBytes: metadata.allocatedBytes,
                        deletionMode: .deleteImmediately,
                        reason: kind.rawValue
                    )
                )
            }
        }

        walk(root)
        return CategoryScan(candidates: candidates, accessIssues: accessIssues)
    }

    private static func allocatedSize(
        of url: URL,
        filesystem: any DiskCleanupFilesystem
    ) -> UInt64? {
        guard let metadata = try? filesystem.itemMetadata(at: url) else { return nil }
        guard metadata.isSymbolicLink == false else { return nil }

        var total = metadata.allocatedBytes
        guard metadata.isDirectory else { return total }

        guard let children = try? filesystem.contentsOfDirectory(at: url) else { return total }
        for child in children {
            total += allocatedSize(of: child, filesystem: filesystem) ?? 0
        }
        return total
    }

    private static func summary(
        for kind: DiskCleanupCategoryKind,
        candidates: [DiskCleanupCandidate],
        accessIssueCount: Int
    ) -> DiskCleanupCategorySummary {
        let totalBytes = candidates.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
        let selectedCandidates = candidates.filter(\.isDefaultSelected)
        let selectedBytes = selectedCandidates.reduce(UInt64(0)) { $0 + $1.allocatedBytes }
        return DiskCleanupCategorySummary(
            kind: kind,
            titleKey: kind.rawValue,
            totalBytes: totalBytes,
            selectedBytes: selectedBytes,
            itemCount: candidates.count,
            selectedItemCount: selectedCandidates.count,
            accessIssueCount: accessIssueCount
        )
    }

    private static func isOldEnough(_ metadata: DiskCleanupItemMetadata, now: Date) -> Bool {
        guard let modifiedAt = metadata.contentModificationDate else { return true }
        return now.timeIntervalSince(modifiedAt) >= 86_400
    }

    private static func isExcludedCachePath(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relativePath = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
        let components = relativePath
            .split(separator: "/")
            .map(String.init)

        return components.contains { component in
            component == "CloudKit"
                || component == "Metadata"
                || component == "Family"
                || component == "Mobile Documents"
                || component.hasPrefix("com.apple")
        }
    }

    private static func isLogFileName(_ name: String) -> Bool {
        name.hasSuffix(".log")
            || name.hasSuffix(".txt")
            || name.contains(".log.")
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = normalizedPath(root)
        let path = normalizedPath(url)
        return path.hasPrefix(rootPath + "/")
    }

    private static func isSafeToDelete(
        _ candidate: DiskCleanupCandidate,
        roots: DiskCleanupRoots,
        filesystem: any DiskCleanupFilesystem
    ) -> Bool {
        let root = roots.url(for: candidate.kind)
        guard isContained(candidate.url, in: root) else { return false }
        guard let metadata = try? filesystem.itemMetadata(at: candidate.url) else { return false }
        guard metadata.isSymbolicLink == false else { return false }
        guard candidate.kind == .trash || metadata.isDirectory == false else { return false }
        guard isContained(candidate.url.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath()) else { return false }
        return true
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private struct CategoryScan {
        var candidates: [DiskCleanupCandidate] = []
        var accessIssues: [DiskCleanupAccessIssue] = []
    }
}
