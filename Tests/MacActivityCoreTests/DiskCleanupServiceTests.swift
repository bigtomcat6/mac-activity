import XCTest
@testable import MacActivityCore

final class DiskCleanupServiceTests: XCTestCase {
    func testScanReportsSelectedTrashBytesAsCleanableNow() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let trashURL = roots.url(for: .trash)
        let cacheURL = roots.url(for: .userCaches)
        let logURL = roots.url(for: .userLogs)
        let visible = trashURL.appendingPathComponent("cache.bin")
        let hidden = trashURL.appendingPathComponent(".hidden-cache")
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [
                trashURL: [visible, hidden],
                cacheURL: [],
                logURL: [],
            ],
            itemInfo: [
                visible: .file(size: 4_096, modifiedAt: .distantPast),
                hidden: .file(size: 2_048, modifiedAt: .distantPast),
            ]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.scan(categories: [.trash, .userCaches, .userLogs], now: Date())

        guard case .cleanable(let summary) = result else {
            return XCTFail("Expected cleanable summary, got \(result)")
        }
        XCTAssertEqual(summary.selectedBytes, 6_144)
        XCTAssertEqual(summary.totalBytes, 6_144)
        XCTAssertEqual(summary.selectedItemCount, 2)
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.categories.map(\.kind), [.trash])
        XCTAssertEqual(summary.categories.first?.selectedBytes, 6_144)
    }

    func testCleanDeletesSelectedTrashChildrenButNotTrashDirectory() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let trashURL = roots.url(for: .trash)
        let child = trashURL.appendingPathComponent("old.log")
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [trashURL: [child]],
            itemInfo: [child: .file(size: 512, modifiedAt: .distantPast)]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.clean(categories: [.trash], now: Date())

        XCTAssertEqual(result, .cleaned(bytes: 512, itemCount: 1))
        XCTAssertEqual(filesystem.removedItems(), [child])
        XCTAssertFalse(filesystem.removedItems().contains(trashURL))
    }

    func testPartialCleanupReportsDeletedAndFailedCountsWithRemainingBytes() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let trashURL = roots.url(for: .trash)
        let ok = trashURL.appendingPathComponent("ok.tmp")
        let blocked = trashURL.appendingPathComponent("blocked.tmp")
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [trashURL: [ok, blocked]],
            itemInfo: [
                ok: .file(size: 100, modifiedAt: .distantPast),
                blocked: .file(size: 200, modifiedAt: .distantPast),
            ],
            removeFailures: [blocked: TestDiskCleanupError.denied]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.clean(categories: [.trash], now: Date())

        XCTAssertEqual(result, .partial(bytes: 100, deletedCount: 1, failedCount: 1, remainingBytes: 200))
        XCTAssertEqual(filesystem.removedItems(), [ok, blocked])
    }

    func testCleanRevalidatesCandidateBeforeDeleting() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let trashURL = roots.url(for: .trash)
        let replaced = trashURL.appendingPathComponent("replaced.tmp")
        let filesystem = ReplacingDiskCleanupFilesystem(root: trashURL, candidate: replaced)
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.clean(categories: [.trash], now: Date())

        XCTAssertEqual(result, .failed("Unable to delete selected disk cleanup items."))
        XCTAssertEqual(filesystem.removedItems(), [])
    }

    func testCacheScannerSkipsExcludedNamesRecentItemsAndSymlinks() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let cacheURL = roots.url(for: .userCaches)
        let oldSafe = cacheURL.appendingPathComponent("com.example.App/old.cache")
        let oldSafeDirectory = oldSafe.deletingLastPathComponent()
        let excluded = cacheURL.appendingPathComponent("com.apple.Safari/cache.db")
        let excludedDirectory = excluded.deletingLastPathComponent()
        let recent = cacheURL.appendingPathComponent("com.example.App/recent.cache")
        let symlink = cacheURL.appendingPathComponent("com.example.App/link")
        let now = Date()
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [
                cacheURL: [oldSafeDirectory, excludedDirectory],
                oldSafeDirectory: [oldSafe, recent, symlink],
                excludedDirectory: [excluded],
            ],
            itemInfo: [
                oldSafeDirectory: .directory(size: 0, modifiedAt: .distantPast),
                oldSafe: .file(size: 1_000, modifiedAt: now.addingTimeInterval(-172_800)),
                recent: .file(size: 2_000, modifiedAt: now.addingTimeInterval(-3_600)),
                symlink: .symlink(size: 9, modifiedAt: .distantPast),
                excludedDirectory: .directory(size: 0, modifiedAt: .distantPast),
                excluded: .file(size: 3_000, modifiedAt: .distantPast),
            ]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.scan(categories: [.userCaches], now: now)

        guard case .cleanable(let summary) = result else {
            return XCTFail("Expected cleanable summary, got \(result)")
        }
        XCTAssertEqual(summary.selectedBytes, 1_000)
        XCTAssertEqual(summary.selectedItemCount, 1)
        XCTAssertEqual(summary.candidates.map(\.url), [oldSafe])
    }

    func testLogScannerIncludesOldLogsAndSkipsRecentLogs() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let logURL = roots.url(for: .userLogs)
        let oldLog = logURL.appendingPathComponent("app.log")
        let oldCompressedLog = logURL.appendingPathComponent("app.log.1.gz")
        let recentLog = logURL.appendingPathComponent("recent.log")
        let notLog = logURL.appendingPathComponent("notes.json")
        let now = Date()
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [logURL: [oldLog, oldCompressedLog, recentLog, notLog]],
            itemInfo: [
                oldLog: .file(size: 100, modifiedAt: now.addingTimeInterval(-172_800)),
                oldCompressedLog: .file(size: 200, modifiedAt: now.addingTimeInterval(-172_800)),
                recentLog: .file(size: 400, modifiedAt: now.addingTimeInterval(-3_600)),
                notLog: .file(size: 800, modifiedAt: .distantPast),
            ]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.scan(categories: [.userLogs], now: now)

        guard case .cleanable(let summary) = result else {
            return XCTFail("Expected cleanable summary, got \(result)")
        }
        XCTAssertEqual(summary.selectedBytes, 300)
        XCTAssertEqual(summary.selectedItemCount, 2)
        XCTAssertEqual(summary.candidates.map(\.url), [oldLog, oldCompressedLog])
    }

    func testScanFailureInOneCategoryPreservesSuccessfulCategoriesAsAccessIssue() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let trashURL = roots.url(for: .trash)
        let cacheURL = roots.url(for: .userCaches)
        let logURL = roots.url(for: .userLogs)
        let trashItem = trashURL.appendingPathComponent("old.tmp")
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [
                trashURL: [trashItem],
                logURL: [],
            ],
            itemInfo: [trashItem: .file(size: 128, modifiedAt: .distantPast)],
            contentsFailures: [cacheURL: TestDiskCleanupError.denied]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.scan(categories: [.trash, .userCaches, .userLogs], now: Date())

        guard case .cleanable(let summary) = result else {
            return XCTFail("Expected cleanable summary, got \(result)")
        }
        XCTAssertEqual(summary.selectedBytes, 128)
        XCTAssertEqual(summary.accessIssueCount, 1)
        XCTAssertEqual(summary.categories.map(\.kind), [.trash])
    }
}

private enum TestDiskCleanupError: Error, LocalizedError {
    case denied

    var errorDescription: String? { "denied" }
}

private final class ReplacingDiskCleanupFilesystem: DiskCleanupFilesystem, @unchecked Sendable {
    private let root: URL
    private let candidate: URL
    private var metadataReadCount = 0
    private var removed: [URL] = []

    init(root: URL, candidate: URL) {
        self.root = root
        self.candidate = candidate
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        url == root ? [candidate] : []
    }

    func itemMetadata(at url: URL) throws -> DiskCleanupItemMetadata {
        metadataReadCount += 1
        return DiskCleanupItemMetadata(
            allocatedBytes: 512,
            isDirectory: false,
            isSymbolicLink: metadataReadCount > 1,
            contentModificationDate: .distantPast
        )
    }

    func removeItem(at url: URL) throws {
        removed.append(url)
    }

    func trashItem(at url: URL) throws {
        removed.append(url)
    }

    func removedItems() -> [URL] {
        removed
    }
}

private final class DiskCleanupFilesystemRecorder: DiskCleanupFilesystem, @unchecked Sendable {
    struct ItemInfo: Sendable {
        enum Kind: Sendable {
            case file
            case directory
            case symlink
        }

        let kind: Kind
        let size: UInt64
        let modifiedAt: Date

        static func file(size: UInt64, modifiedAt: Date) -> ItemInfo {
            ItemInfo(kind: .file, size: size, modifiedAt: modifiedAt)
        }

        static func directory(size: UInt64, modifiedAt: Date) -> ItemInfo {
            ItemInfo(kind: .directory, size: size, modifiedAt: modifiedAt)
        }

        static func symlink(size: UInt64, modifiedAt: Date) -> ItemInfo {
            ItemInfo(kind: .symlink, size: size, modifiedAt: modifiedAt)
        }
    }

    var contents: [URL: [URL]]
    var itemInfo: [URL: ItemInfo]
    var contentsFailures: [URL: Error]
    var removeFailures: [URL: Error]

    private var removed: [URL] = []

    init(
        contents: [URL: [URL]] = [:],
        itemInfo: [URL: ItemInfo] = [:],
        contentsFailures: [URL: Error] = [:],
        removeFailures: [URL: Error] = [:]
    ) {
        self.contents = contents
        self.itemInfo = itemInfo
        self.contentsFailures = contentsFailures
        self.removeFailures = removeFailures
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        if let error = contentsFailures[url] { throw error }
        return contents[url] ?? []
    }

    func itemMetadata(at url: URL) throws -> DiskCleanupItemMetadata {
        let info = itemInfo[url] ?? .file(size: 0, modifiedAt: .distantPast)
        return DiskCleanupItemMetadata(
            allocatedBytes: info.size,
            isDirectory: info.kind == .directory,
            isSymbolicLink: info.kind == .symlink,
            contentModificationDate: info.modifiedAt
        )
    }

    func removeItem(at url: URL) throws {
        removed.append(url)
        if let error = removeFailures[url] { throw error }
    }

    func trashItem(at url: URL) throws {
        removed.append(url)
        if let error = removeFailures[url] { throw error }
    }

    func removedItems() -> [URL] {
        removed
    }
}
