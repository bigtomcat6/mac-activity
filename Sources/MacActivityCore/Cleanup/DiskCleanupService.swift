import Foundation
import Darwin

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
    public let containmentDirectory: URL?

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(
            trashDirectory: homeDirectory.appendingPathComponent(".Trash", isDirectory: true),
            userCachesDirectory: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true),
            userLogsDirectory: homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true),
            containmentDirectory: homeDirectory
        )
    }

    public init(
        trashDirectory: URL,
        userCachesDirectory: URL,
        userLogsDirectory: URL,
        containmentDirectory: URL? = nil
    ) {
        self.trashDirectory = trashDirectory
        self.userCachesDirectory = userCachesDirectory
        self.userLogsDirectory = userLogsDirectory
        self.containmentDirectory = containmentDirectory
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
    func scoped(to roots: DiskCleanupRoots) -> any DiskCleanupFilesystem
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func itemMetadata(at url: URL) throws -> DiskCleanupItemMetadata
    func removeItem(at url: URL) throws
    func removeItem(at url: URL, allowDirectory: Bool) throws
    func trashItem(at url: URL) throws
    func trashItem(at url: URL, allowDirectory: Bool) throws
}

public extension DiskCleanupFilesystem {
    // Injected filesystems retain their own namespace and mutation semantics.
    func scoped(to roots: DiskCleanupRoots) -> any DiskCleanupFilesystem { self }
    func removeItem(at url: URL, allowDirectory: Bool) throws { try removeItem(at: url) }
    func trashItem(at url: URL, allowDirectory: Bool) throws { try trashItem(at: url) }
}

public struct LiveDiskCleanupFilesystem: DiskCleanupFilesystem {
    private var session: DiskCleanupFilesystemSession?
    private var mutationHook: (@Sendable (URL, DiskCleanupMutationPhase) throws -> Void)?
    private var trashOperation: @Sendable (URL) throws -> Void = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }
    private var replacementDirectory: @Sendable (URL) throws -> URL = { url in
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
    }

    public init() {}

    init(
        mutationHook: (@Sendable (URL, DiskCleanupMutationPhase) throws -> Void)? = nil,
        trashOperation: (@Sendable (URL) throws -> Void)? = nil,
        replacementDirectory: (@Sendable (URL) throws -> URL)? = nil
    ) {
        self.mutationHook = mutationHook
        if let trashOperation { self.trashOperation = trashOperation }
        if let replacementDirectory { self.replacementDirectory = replacementDirectory }
    }

    public func scoped(to roots: DiskCleanupRoots) -> any DiskCleanupFilesystem {
        var filesystem = self
        filesystem.session = DiskCleanupFilesystemSession(roots: roots)
        return filesystem
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let directory = try session?.directory(at: url) ?? DiskCleanupDirectory.openAbsolute(url)
        return try directory.names().map { url.appendingPathComponent($0) }
    }

    public func itemMetadata(at url: URL) throws -> DiskCleanupItemMetadata {
        let (parent, name) = try parent(of: url)
        let values = try parent.metadata(name)
        return DiskCleanupItemMetadata(
            allocatedBytes: UInt64(max(0, values.st_blocks)) * 512,
            isDirectory: values.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            isSymbolicLink: values.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
            contentModificationDate: Date(timeIntervalSince1970: Double(values.st_mtimespec.tv_sec))
        )
    }

    public func removeItem(at url: URL) throws {
        try removeItem(at: url, allowDirectory: true)
    }

    public func removeItem(at url: URL, allowDirectory: Bool) throws {
        let (parent, name) = try parent(of: url)
        try removeEntry(
            name,
            in: parent,
            url: url,
            allowDirectory: allowDirectory,
            allowSymbolicLink: false
        )
    }

    public func trashItem(at url: URL) throws {
        try trashItem(at: url, allowDirectory: true)
    }

    public func trashItem(at url: URL, allowDirectory: Bool) throws {
        let (parent, name) = try parent(of: url)
        try mutationHook?(url, .parentOpened)
        let original = try parent.metadata(name)
        let originalKind = original.st_mode & mode_t(S_IFMT)
        guard originalKind != mode_t(S_IFLNK), allowDirectory || originalKind != mode_t(S_IFDIR) else {
            throw DiskCleanupDirectory.error(ELOOP)
        }

        // Foundation's Trash API requires a pathname. First acquire the source
        // with renameat into a private, same-volume replacement directory whose
        // ancestors cannot be renamed by the different-user fixture attacker.
        let stagingURL = try replacementDirectory(url)
        let staging = try DiskCleanupDirectory.openAbsolute(stagingURL, requireTrustedAncestors: true)
        let stagingInfo = try staging.metadata(".")
        guard stagingInfo.st_uid == geteuid() else { throw DiskCleanupDirectory.error(EPERM) }
        guard fchmod(staging.descriptor, 0o700) == 0 else { throw DiskCleanupDirectory.error() }
        let stagingParent = try DiskCleanupDirectory.openAbsolute(stagingURL.deletingLastPathComponent(), requireTrustedAncestors: true)
        defer { _ = unlinkat(stagingParent.descriptor, stagingURL.lastPathComponent, AT_REMOVEDIR) }
        guard renameatx_np(parent.descriptor, name, staging.descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
            throw DiskCleanupDirectory.error()
        }
        do {
            let acquired = try staging.metadata(name)
            guard acquired.st_dev == original.st_dev, acquired.st_ino == original.st_ino else {
                throw DiskCleanupDirectory.error(ESTALE)
            }
            try trashOperation(stagingURL.appendingPathComponent(name))
        } catch {
            // Never overwrite a replacement at the original name or delete a
            // staged item when Trash fails. Leave recoverable data on conflict.
            if renameatx_np(staging.descriptor, name, parent.descriptor, name, UInt32(RENAME_EXCL)) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "Trash failed; item preserved at \(stagingURL.appendingPathComponent(name).path): \(error.localizedDescription)"
                ])
            }
            throw error
        }
    }

    private func parent(of url: URL) throws -> (DiskCleanupDirectory, String) {
        if let session { return try session.parent(of: url) }
        guard url.isFileURL, url.pathComponents.count > 1 else { throw DiskCleanupDirectory.error(EINVAL) }
        return (try DiskCleanupDirectory.openAbsolute(url.deletingLastPathComponent()), url.lastPathComponent)
    }

    private func removeEntry(
        _ name: String,
        in parent: DiskCleanupDirectory,
        url: URL,
        allowDirectory: Bool,
        allowSymbolicLink: Bool
    ) throws {
        try mutationHook?(url, .parentOpened)
        let info = try parent.metadata(name)
        let kind = info.st_mode & mode_t(S_IFMT)
        if kind == mode_t(S_IFLNK), !allowSymbolicLink { throw DiskCleanupDirectory.error(ELOOP) }
        if kind == mode_t(S_IFDIR) {
            guard allowDirectory else { throw DiskCleanupDirectory.error(EISDIR) }
            let directory = try parent.open([name])
            let opened = try directory.metadata(".")
            guard opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                throw DiskCleanupDirectory.error(ESTALE)
            }
            try mutationHook?(url, .directoryOpened)
            for child in try directory.names() {
                try removeEntry(
                    child,
                    in: directory,
                    url: url.appendingPathComponent(child),
                    allowDirectory: true,
                    allowSymbolicLink: true
                )
            }
            guard unlinkat(parent.descriptor, name, AT_REMOVEDIR) == 0 else { throw DiskCleanupDirectory.error() }
        } else {
            // unlinkat removes a substituted symlink itself, never its target.
            guard unlinkat(parent.descriptor, name, 0) == 0 else { throw DiskCleanupDirectory.error() }
        }
    }
}

enum DiskCleanupMutationPhase: Sendable {
    case parentOpened
    case directoryOpened
}

private struct DiskCleanupFilesystemSession: Sendable {
    private struct Root: Sendable {
        let url: URL
        let directory: Result<DiskCleanupDirectory, Error>
    }
    private let roots: [Root]

    init(roots: DiskCleanupRoots) {
        let anchor = roots.containmentDirectory.map { url in Result { try DiskCleanupDirectory.openAbsolute(url) } }
        self.roots = DiskCleanupCategoryKind.allCases.map { kind in
            let url = roots.url(for: kind)
            return Root(url: url, directory: Result {
                if let anchor, let anchorURL = roots.containmentDirectory {
                    let components = try Self.relativeComponents(url, beneath: anchorURL, allowRoot: false)
                    return try anchor.get().open(components)
                }
                return try DiskCleanupDirectory.openAbsolute(url)
            })
        }
    }

    func directory(at url: URL) throws -> DiskCleanupDirectory {
        let (root, components) = try location(of: url, allowRoot: true)
        return try root.directory.get().open(components)
    }

    func parent(of url: URL) throws -> (DiskCleanupDirectory, String) {
        let (root, components) = try location(of: url, allowRoot: false)
        guard let name = components.last else { throw DiskCleanupDirectory.error(EINVAL) }
        return (try root.directory.get().open(Array(components.dropLast())), name)
    }

    private func location(of url: URL, allowRoot: Bool) throws -> (Root, [String]) {
        if !allowRoot,
           roots.contains(where: { Self.hasSameLexicalPath(url, $0.url) }) {
            throw DiskCleanupDirectory.error(EPERM)
        }
        for root in roots.sorted(by: { $0.url.path.count > $1.url.path.count }) {
            if let components = try? Self.relativeComponents(url, beneath: root.url, allowRoot: allowRoot) {
                return (root, components)
            }
        }
        throw DiskCleanupDirectory.error(EPERM)
    }

    private static func hasSameLexicalPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.isFileURL && rhs.isFileURL
            && canonicalPathComponents(lhs) == canonicalPathComponents(rhs)
    }

    private static func relativeComponents(_ url: URL, beneath root: URL, allowRoot: Bool) throws -> [String] {
        guard url.isFileURL, root.isFileURL else { throw DiskCleanupDirectory.error(EINVAL) }
        let path = canonicalPathComponents(url)
        let prefix = canonicalPathComponents(root)
        guard path.starts(with: prefix), path.count > prefix.count || allowRoot else {
            throw DiskCleanupDirectory.error(EPERM)
        }
        return Array(path.dropFirst(prefix.count))
    }

    private static func canonicalPathComponents(_ url: URL) -> [String] {
        var components = url.standardizedFileURL.pathComponents
        if components.count > 1,
           components[1] == "tmp" || components[1] == "var" {
            components.insert("private", at: 1)
        }
        return components
    }
}

private final class DiskCleanupDirectory: @unchecked Sendable {
    let descriptor: Int32
    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func error(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    static func openAbsolute(_ url: URL, requireTrustedAncestors: Bool = false) throws -> DiskCleanupDirectory {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw error(EINVAL) }
        var components = Array(url.standardizedFileURL.pathComponents.dropFirst())
        // These are macOS system aliases, not fixture-controlled symlinks.
        if components.first == "tmp" || components.first == "var" { components.insert("private", at: 0) }
        let descriptor = Darwin.open("/", flags)
        guard descriptor >= 0 else { throw error() }
        var directory = DiskCleanupDirectory(descriptor)
        for component in components {
            directory = try directory.open([component])
            if requireTrustedAncestors {
                let info = try directory.metadata(".")
                let trustedOwner = info.st_uid == 0 || info.st_uid == geteuid()
                let protectedFromRename = info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0
                guard trustedOwner, protectedFromRename else { throw error(EPERM) }
            }
        }
        return directory
    }

    func open(_ components: [String]) throws -> DiskCleanupDirectory {
        let copy = openat(descriptor, ".", Self.flags)
        guard copy >= 0 else { throw Self.error() }
        var directory = DiskCleanupDirectory(copy)
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw Self.error(EINVAL)
            }
            let next = openat(directory.descriptor, component, Self.flags)
            guard next >= 0 else { throw Self.error() }
            directory = DiskCleanupDirectory(next)
        }
        return directory
    }

    func metadata(_ name: String) throws -> stat {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.error() }
        return info
    }

    func names() throws -> [String] {
        let copy = openat(descriptor, ".", Self.flags)
        guard copy >= 0 else { throw Self.error() }
        guard let stream = fdopendir(copy) else {
            let failure = Self.error()
            close(copy)
            throw failure
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.error() }
                return names
            }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }
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
    case failed(DiskCleanupFailureReason)
}

public enum DiskCleanupFailureReason: Equatable, Sendable {
    case message(String)
    case unableToDeleteItems
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
            Self.scan(categories: categories, now: now, roots: roots, filesystem: filesystem.scoped(to: roots))
        }.value
    }

    public func clean(
        categories: [DiskCleanupCategoryKind] = DiskCleanupCategoryKind.allCases,
        now: Date = Date()
    ) async -> DiskCleanupResult {
        let roots = self.roots
        let filesystem = self.filesystem

        return await Task.detached(priority: .utility) {
            Self.clean(categories: categories, now: now, roots: roots, filesystem: filesystem.scoped(to: roots))
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
            return .failed(.message(message))
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
                    try filesystem.removeItem(at: candidate.url, allowDirectory: candidate.kind == .trash)
                case .moveToTrash:
                    try filesystem.trashItem(at: candidate.url, allowDirectory: candidate.kind == .trash)
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
            return .failed(.unableToDeleteItems)
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

                let metadata: DiskCleanupItemMetadata
                do {
                    metadata = try filesystem.itemMetadata(at: child)
                } catch {
                    accessIssues.append(DiskCleanupAccessIssue(kind: kind, url: child, message: error.localizedDescription))
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
