import XCTest
@testable import MacActivityCore

final class DiskCleanupServiceTests: XCTestCase {
    func testLiveCleanupRejectsEverySymlinkedCategoryRoot() async throws {
        for kind in DiskCleanupCategoryKind.allCases {
            let fixture = try CleanupSecurityFixture()
            defer { fixture.remove() }
            let sentinel = try fixture.file("outside.log", beneath: fixture.outside)
            let root = fixture.roots.url(for: kind)
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: fixture.outside)

            let result = await DiskCleanupService(roots: fixture.roots).clean(categories: [kind])

            guard case .failed = result else { return XCTFail("Expected unsafe category rejection: \(kind), \(result)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    func testLiveCleanupRejectsSymlinkedLibraryAndFixtureAncestors() async throws {
        for replaceFixture in [false, true] {
            let fixture = try CleanupSecurityFixture()
            defer { fixture.remove() }
            let source = replaceFixture ? fixture.home : fixture.home.appendingPathComponent("Library")
            let externalCaches = fixture.outside.appendingPathComponent(replaceFixture ? "Library/Caches" : "Caches")
            let sentinel = try fixture.file("outside.cache", beneath: externalCaches)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: fixture.outside)

            let result = await DiskCleanupService(roots: fixture.roots).clean(categories: [.userCaches])

            guard case .failed = result else { return XCTFail("Expected linked ancestor rejection: \(result)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    func testLiveCleanupPreservesLegitimateSelectionsAndNestedTrashSemantics() async throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let sentinel = try fixture.file("outside.cache", beneath: fixture.outside)
        let trashDirectory = fixture.roots.trashDirectory.appendingPathComponent("bundle")
        _ = try fixture.file("nested/.hidden", beneath: trashDirectory)
        try FileManager.default.createSymbolicLink(at: trashDirectory.appendingPathComponent("external-link"), withDestinationURL: fixture.outside)
        let cache = try fixture.file("com.example/old.cache", beneath: fixture.roots.userCachesDirectory)
        let recent = try fixture.file("com.example/recent.cache", beneath: fixture.roots.userCachesDirectory, old: false)
        let excluded = try fixture.file("com.apple.example/old.cache", beneath: fixture.roots.userCachesDirectory)
        let log = try fixture.file("app.log.1", beneath: fixture.roots.userLogsDirectory)

        let result = await DiskCleanupService(roots: fixture.roots).clean()

        guard case .cleaned(_, let count) = result else { return XCTFail("Expected normal cleanup: \(result)") }
        XCTAssertEqual(count, 3)
        for removed in [trashDirectory, cache, log] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        }
        for preserved in [recent, excluded, sentinel] + DiskCleanupCategoryKind.allCases.map({ fixture.roots.url(for: $0) }) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        }
    }

    func testLiveCleanupPinsParentAcrossPostValidationDirectorySwap() async throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let parent = fixture.roots.userCachesDirectory.appendingPathComponent("app")
        let candidate = try fixture.file("old.cache", beneath: parent)
        let sentinel = try fixture.file("old.cache", beneath: fixture.outside)
        let savedParent = fixture.home.appendingPathComponent("saved-parent")
        let filesystem = LiveDiskCleanupFilesystem(mutationHook: { url, phase in
            guard url == candidate, phase == .parentOpened else { return }
            try FileManager.default.moveItem(at: parent, to: savedParent)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.outside)
        })

        let result = await DiskCleanupService(roots: fixture.roots, filesystem: filesystem).clean(categories: [.userCaches])

        guard case .cleaned(_, 1) = result else { return XCTFail("Expected deletion through pinned parent: \(result)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedParent.appendingPathComponent("old.cache").path))
    }

    func testScopedFilesystemPinsCategoryRootBeforeItIsReplaced() throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let root = fixture.roots.userCachesDirectory
        let candidate = try fixture.file("old.cache", beneath: root)
        let sentinel = try fixture.file("old.cache", beneath: fixture.outside)
        let filesystem = LiveDiskCleanupFilesystem().scoped(to: fixture.roots)
        let moved = fixture.home.appendingPathComponent("saved-caches")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: fixture.outside)

        try filesystem.removeItem(at: candidate)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("old.cache").path))
    }

    func testLiveCleanupNeverTraversesDirectoryReplacedDuringRecursion() async throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let directory = fixture.roots.trashDirectory.appendingPathComponent("bundle")
        _ = try fixture.file("old.cache", beneath: directory)
        let sentinel = try fixture.file("old.cache", beneath: fixture.outside)
        let saved = fixture.home.appendingPathComponent("saved-bundle")
        let filesystem = LiveDiskCleanupFilesystem(mutationHook: { url, phase in
            guard url.path == directory.path, phase == .directoryOpened else { return }
            try FileManager.default.moveItem(at: directory, to: saved)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.outside)
        })

        let result = await DiskCleanupService(roots: fixture.roots, filesystem: filesystem).clean(categories: [.trash])

        guard case .failed = result else { return XCTFail("Expected replaced directory removal to fail: \(result)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("old.cache").path))
    }

    func testLiveCleanupRejectsLeafReplacedAfterValidation() async throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let candidate = try fixture.file("old.cache", beneath: fixture.roots.userCachesDirectory)
        let sentinel = try fixture.file("old.cache", beneath: fixture.outside)
        let filesystem = LiveDiskCleanupFilesystem(mutationHook: { url, phase in
            guard url == candidate, phase == .parentOpened else { return }
            try FileManager.default.removeItem(at: candidate)
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: sentinel)
        })

        let result = await DiskCleanupService(roots: fixture.roots, filesystem: filesystem).clean(categories: [.userCaches])

        guard case .failed = result else { return XCTFail("Expected symlink rejection: \(result)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testLiveCleanupRejectsCacheFileReplacedByDirectoryAfterValidation() async throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let candidate = try fixture.file("old.cache", beneath: fixture.roots.userCachesDirectory)
        let replacementChild = candidate.appendingPathComponent("recent.cache")
        let filesystem = LiveDiskCleanupFilesystem(mutationHook: { url, phase in
            guard url == candidate, phase == .parentOpened else { return }
            try FileManager.default.removeItem(at: candidate)
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
            try Data("recent".utf8).write(to: replacementChild)
        })

        let result = await DiskCleanupService(roots: fixture.roots, filesystem: filesystem)
            .clean(categories: [.userCaches])

        guard case .failed = result else { return XCTFail("Expected directory replacement rejection: \(result)") }
        XCTAssertEqual(try Data(contentsOf: replacementChild), Data("recent".utf8))
    }

    func testScopedFilesystemRejectsOutsidePathsAndCategoryRootDeletion() throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let sentinel = try fixture.file("old.cache", beneath: fixture.outside)
        let filesystem = LiveDiskCleanupFilesystem().scoped(to: fixture.roots)
        XCTAssertThrowsError(try filesystem.removeItem(at: sentinel))
        XCTAssertThrowsError(try filesystem.removeItem(at: fixture.roots.userCachesDirectory))
        XCTAssertThrowsError(try filesystem.removeItem(at: fixture.roots.userCachesDirectory.appendingPathComponent("../../outside/old.cache")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testScopedFilesystemRejectsOverlappingCategoryRootDeletion() throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let broadRoot = fixture.home.appendingPathComponent("shared")
        let nestedRoot = broadRoot.appendingPathComponent("caches")
        let logRoot = fixture.home.appendingPathComponent("logs")
        for root in [nestedRoot, logRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let sentinel = try fixture.file("old.cache", beneath: nestedRoot)
        let aliasedNestedRoot = URL(
            fileURLWithPath: nestedRoot.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        )
        let roots = DiskCleanupRoots(
            trashDirectory: broadRoot,
            userCachesDirectory: aliasedNestedRoot,
            userLogsDirectory: logRoot
        )
        let filesystem = LiveDiskCleanupFilesystem().scoped(to: roots)

        XCTAssertThrowsError(try filesystem.removeItem(at: nestedRoot))
        XCTAssertThrowsError(try filesystem.trashItem(at: nestedRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testTrashCleanupDoesNotDeleteNestedUnselectedCategoryRoot() async throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let broadRoot = fixture.home.appendingPathComponent("shared")
        let nestedRoot = broadRoot.appendingPathComponent("caches")
        let sentinel = try fixture.file("old.cache", beneath: nestedRoot)
        let roots = DiskCleanupRoots(
            trashDirectory: broadRoot,
            userCachesDirectory: nestedRoot,
            userLogsDirectory: fixture.roots.userLogsDirectory
        )

        let result = await DiskCleanupService(roots: roots).clean(categories: [.trash])

        XCTAssertEqual(result, .cleaned(bytes: 0, itemCount: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testLiveCleanupSupportsCustomRootsAndSystemTemporaryAliases() async throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let candidate = try fixture.file("old.cache", beneath: fixture.roots.userCachesDirectory)
        let aliasPath = fixture.home.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        let aliased = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: aliasPath))
        let custom = DiskCleanupRoots(trashDirectory: aliased.trashDirectory, userCachesDirectory: aliased.userCachesDirectory, userLogsDirectory: aliased.userLogsDirectory)

        let result = await DiskCleanupService(roots: custom).clean(categories: [.userCaches])

        guard case .cleaned(_, 1) = result else { return XCTFail("Expected normal custom/aliased root: \(result)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testTrashAcquiresSourceBeforeCallingPathBasedAPI() throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let candidate = try fixture.file("old.cache", beneath: fixture.roots.userCachesDirectory)
        let staging = fixture.container.appendingPathComponent("staging")
        let destination = fixture.outside.appendingPathComponent("trashed.cache")
        let filesystem = LiveDiskCleanupFilesystem(
            trashOperation: { staged in
                XCTAssertEqual(staged.lastPathComponent, candidate.lastPathComponent)
                XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
                try FileManager.default.moveItem(at: staged, to: destination)
            },
            replacementDirectory: { _ in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return staging
            }
        ).scoped(to: fixture.roots)

        try filesystem.trashItem(at: candidate)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testTrashFailureRestoresOriginalWithoutLosingData() throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let candidate = try fixture.file("old.cache", beneath: fixture.roots.userCachesDirectory)
        let staging = fixture.container.appendingPathComponent("staging")
        let filesystem = LiveDiskCleanupFilesystem(
            trashOperation: { _ in throw TestDiskCleanupError.denied },
            replacementDirectory: { _ in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return staging
            }
        ).scoped(to: fixture.roots)

        XCTAssertThrowsError(try filesystem.trashItem(at: candidate))

        XCTAssertEqual(try Data(contentsOf: candidate), Data(repeating: 65, count: 4096))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testTrashFailureNeverOverwritesNewSourceEntry() throws {
        let fixture = try CleanupSecurityFixture()
        defer { fixture.remove() }
        let candidate = try fixture.file("old.cache", beneath: fixture.roots.userCachesDirectory)
        let staging = fixture.container.appendingPathComponent("staging")
        let filesystem = LiveDiskCleanupFilesystem(
            trashOperation: { _ in
                try Data("replacement".utf8).write(to: candidate)
                throw TestDiskCleanupError.denied
            },
            replacementDirectory: { _ in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return staging
            }
        ).scoped(to: fixture.roots)

        XCTAssertThrowsError(try filesystem.trashItem(at: candidate))

        XCTAssertEqual(try Data(contentsOf: candidate), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent(candidate.lastPathComponent)), Data(repeating: 65, count: 4096))
    }

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
                logURL: []
            ],
            itemInfo: [
                visible: .file(size: 4_096, modifiedAt: .distantPast),
                hidden: .file(size: 2_048, modifiedAt: .distantPast)
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
        let removable = trashURL.appendingPathComponent("ok.tmp")
        let blocked = trashURL.appendingPathComponent("blocked.tmp")
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [trashURL: [removable, blocked]],
            itemInfo: [
                removable: .file(size: 100, modifiedAt: .distantPast),
                blocked: .file(size: 200, modifiedAt: .distantPast)
            ],
            removeFailures: [blocked: TestDiskCleanupError.denied]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.clean(categories: [.trash], now: Date())

        XCTAssertEqual(result, .partial(bytes: 100, deletedCount: 1, failedCount: 1, remainingBytes: 200))
        XCTAssertEqual(filesystem.removedItems(), [removable, blocked])
    }

    func testCleanRevalidatesCandidateBeforeDeleting() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let trashURL = roots.url(for: .trash)
        let replaced = trashURL.appendingPathComponent("replaced.tmp")
        let filesystem = ReplacingDiskCleanupFilesystem(root: trashURL, candidate: replaced)
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.clean(categories: [.trash], now: Date())

        XCTAssertEqual(result, .failed(.unableToDeleteItems))
        XCTAssertEqual(filesystem.removedItems(), [])
    }

    func testCleanReturnsScanFailureWithoutDeleting() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let cacheURL = roots.url(for: .userCaches)
        let blocked = cacheURL.appendingPathComponent("Blocked")
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [cacheURL: [blocked]],
            itemInfoFailures: [blocked: TestDiskCleanupError.denied]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.clean(categories: [.userCaches], now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(result, .failed(.message("denied")))
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
                excludedDirectory: [excluded]
            ],
            itemInfo: [
                oldSafeDirectory: .directory(size: 0, modifiedAt: .distantPast),
                oldSafe: .file(size: 1_000, modifiedAt: now.addingTimeInterval(-172_800)),
                recent: .file(size: 2_000, modifiedAt: now.addingTimeInterval(-3_600)),
                symlink: .symlink(size: 9, modifiedAt: .distantPast),
                excludedDirectory: .directory(size: 0, modifiedAt: .distantPast),
                excluded: .file(size: 3_000, modifiedAt: .distantPast)
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
                notLog: .file(size: 800, modifiedAt: .distantPast)
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
                logURL: []
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

    func testScanMetadataFailureUsesUnderlyingLocalizedMessage() async {
        let roots = DiskCleanupRoots(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let cacheURL = roots.url(for: .userCaches)
        let unreadable = cacheURL.appendingPathComponent("unreadable.cache")
        let filesystem = DiskCleanupFilesystemRecorder(
            contents: [cacheURL: [unreadable]],
            itemInfoFailures: [unreadable: TestDiskCleanupError.denied]
        )
        let service = DiskCleanupService(roots: roots, filesystem: filesystem)

        let result = await service.scan(categories: [.userCaches], now: Date())

        XCTAssertEqual(result, .failed("denied"))
    }
}

private enum TestDiskCleanupError: Error, LocalizedError {
    case denied

    var errorDescription: String? { "denied" }
}

private struct CleanupSecurityFixture: Sendable {
    let container: URL
    let home: URL
    let outside: URL
    let roots: DiskCleanupRoots

    init() throws {
        container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("macactivity-security-\(UUID().uuidString)")
        home = container.appendingPathComponent("macactivity-fixture")
        outside = container.appendingPathComponent("outside")
        roots = DiskCleanupRoots(homeDirectory: home)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for directory in [outside] + DiskCleanupCategoryKind.allCases.map({ roots.url(for: $0) }) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func file(_ name: String, beneath root: URL, old: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 4096).write(to: url)
        if old {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: url.path)
        }
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: container) }
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

private enum DiskCleanupItemKind: Sendable {
    case file
    case directory
    case symlink
}

private final class DiskCleanupFilesystemRecorder: DiskCleanupFilesystem, @unchecked Sendable {
    struct ItemInfo: Sendable {
        let kind: DiskCleanupItemKind
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
    var itemInfoFailures: [URL: Error]
    var contentsFailures: [URL: Error]
    var removeFailures: [URL: Error]

    private var removed: [URL] = []

    init(
        contents: [URL: [URL]] = [:],
        itemInfo: [URL: ItemInfo] = [:],
        itemInfoFailures: [URL: Error] = [:],
        contentsFailures: [URL: Error] = [:],
        removeFailures: [URL: Error] = [:]
    ) {
        self.contents = contents
        self.itemInfo = itemInfo
        self.itemInfoFailures = itemInfoFailures
        self.contentsFailures = contentsFailures
        self.removeFailures = removeFailures
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        if let error = contentsFailures[url] { throw error }
        return contents[url] ?? []
    }

    func itemMetadata(at url: URL) throws -> DiskCleanupItemMetadata {
        if let error = itemInfoFailures[url] { throw error }
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
