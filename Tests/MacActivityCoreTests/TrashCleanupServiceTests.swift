import XCTest
@testable import MacActivityCore

final class TrashCleanupServiceTests: XCTestCase {
    func testScanReportsCleanableSizeForHomeTrashChildren() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let visible = trashURL.appendingPathComponent("cache.bin")
        let hidden = trashURL.appendingPathComponent(".hidden-cache")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [visible, hidden]],
            allocatedSizes: [visible: 4_096, hidden: 2_048]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.scan()

        XCTAssertEqual(result, .cleanable(bytes: 6_144, itemCount: 2))
    }

    func testScanReportsCleanForEmptyTrash() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let service = TrashCleanupService(
            trashDirectory: trashURL,
            filesystem: TrashFilesystemRecorder(contents: [trashURL: []])
        )

        let result = await service.scan()

        XCTAssertEqual(result, .clean)
    }

    func testScanFailureReportsFailedState() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let filesystem = TrashFilesystemRecorder(contentsFailures: [trashURL: TestTrashError.denied])
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.scan()

        XCTAssertEqual(result, .failed("denied"))
    }

    func testScanTreatsItemSizeFailureAsZeroAndPreservesItemCount() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let readable = trashURL.appendingPathComponent("readable.tmp")
        let unreadable = trashURL.appendingPathComponent("unreadable.tmp")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [readable, unreadable]],
            allocatedSizes: [readable: 1_024],
            allocatedSizeFailures: [unreadable: TestTrashError.denied]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.scan()

        XCTAssertEqual(result, .cleanable(bytes: 1_024, itemCount: 2))
    }

    func testLiveTrashFilesystemReadsNestedAllocatedSizeAndRemovesItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let topFile = root.appendingPathComponent("top.bin")
        let nestedFile = nested.appendingPathComponent("child.bin")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: topFile)
        try Data(repeating: 2, count: 2_048).write(to: nestedFile)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let filesystem = LiveTrashFilesystem()

        XCTAssertEqual(
            Set(try filesystem.contentsOfDirectory(at: root).map { $0.resolvingSymlinksInPath() }),
            Set([nested, topFile].map { $0.resolvingSymlinksInPath() })
        )
        XCTAssertGreaterThan(try filesystem.allocatedSizeOfItem(at: topFile), 0)
        XCTAssertGreaterThanOrEqual(
            try filesystem.allocatedSizeOfItem(at: nested),
            try filesystem.allocatedSizeOfItem(at: nestedFile)
        )

        try filesystem.removeItem(at: topFile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: topFile.path))
    }

    @MainActor
    func testScanRunsFilesystemWorkOffMainThreadWhenCalledFromMainActor() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let child = trashURL.appendingPathComponent("old.log")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [child]],
            allocatedSizes: [child: 512]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.scan()

        XCTAssertEqual(result, .cleanable(bytes: 512, itemCount: 1))
        XCTAssertFalse(filesystem.filesystemWorkRanOnMainThread())
    }

    func testCleanupDeletesChildrenButNotTrashDirectory() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let child = trashURL.appendingPathComponent("old.log")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [child]],
            allocatedSizes: [child: 512]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.clean()

        XCTAssertEqual(result, .cleaned(bytes: 512, itemCount: 1))
        XCTAssertEqual(filesystem.removedItems(), [child])
        XCTAssertFalse(filesystem.removedItems().contains(trashURL))
    }

    func testCleanupReportsPartialFailureAndKeepsSuccessfulDeletes() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let removable = trashURL.appendingPathComponent("ok.tmp")
        let blocked = trashURL.appendingPathComponent("blocked.tmp")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [removable, blocked]],
            allocatedSizes: [removable: 100, blocked: 200],
            removeFailures: [blocked: TestTrashError.denied]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.clean()

        XCTAssertEqual(result, .partial(bytes: 100, deletedCount: 1, failedCount: 1))
        XCTAssertEqual(filesystem.removedItems(), [removable, blocked])
    }

    func testCleanupReportsTotalFailureWhenNoItemsDelete() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let blocked = trashURL.appendingPathComponent("blocked.tmp")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [blocked]],
            allocatedSizes: [blocked: 200],
            removeFailures: [blocked: TestTrashError.denied]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.clean()

        XCTAssertEqual(result, .failed(.unableToDeleteItems))
        XCTAssertEqual(filesystem.removedItems(), [blocked])
    }

    func testCleanupReportsMessageWhenTrashDirectoryCannotBeRead() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let filesystem = TrashFilesystemRecorder(contentsFailures: [trashURL: TestTrashError.denied])
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.clean()

        XCTAssertEqual(result, .failed(.message("denied")))
        XCTAssertEqual(filesystem.removedItems(), [])
    }

    @MainActor
    func testCleanupRunsFilesystemWorkOffMainThreadWhenCalledFromMainActor() async {
        let trashURL = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let child = trashURL.appendingPathComponent("old.log")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [child]],
            allocatedSizes: [child: 512]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.clean()

        XCTAssertEqual(result, .cleaned(bytes: 512, itemCount: 1))
        XCTAssertFalse(filesystem.filesystemWorkRanOnMainThread())
    }
}

private enum TestTrashError: Error, LocalizedError {
    case denied

    var errorDescription: String? { "denied" }
}

private final class TrashFilesystemRecorder: TrashFilesystem, @unchecked Sendable {
    var contents: [URL: [URL]]
    var allocatedSizes: [URL: UInt64]
    var allocatedSizeFailures: [URL: Error]
    var contentsFailures: [URL: Error]
    var removeFailures: [URL: Error]

    private var removed: [URL] = []
    private var mainThreadObservations: [Bool] = []

    init(
        contents: [URL: [URL]] = [:],
        allocatedSizes: [URL: UInt64] = [:],
        allocatedSizeFailures: [URL: Error] = [:],
        contentsFailures: [URL: Error] = [:],
        removeFailures: [URL: Error] = [:]
    ) {
        self.contents = contents
        self.allocatedSizes = allocatedSizes
        self.allocatedSizeFailures = allocatedSizeFailures
        self.contentsFailures = contentsFailures
        self.removeFailures = removeFailures
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        recordThread()
        if let error = contentsFailures[url] { throw error }
        return contents[url] ?? []
    }

    func allocatedSizeOfItem(at url: URL) throws -> UInt64 {
        recordThread()
        if let error = allocatedSizeFailures[url] { throw error }
        return allocatedSizes[url] ?? 0
    }

    func removeItem(at url: URL) throws {
        recordThread()
        removed.append(url)
        if let error = removeFailures[url] { throw error }
    }

    func removedItems() -> [URL] {
        removed
    }

    func filesystemWorkRanOnMainThread() -> Bool {
        mainThreadObservations.contains(true)
    }

    private func recordThread() {
        mainThreadObservations.append(Thread.isMainThread)
    }
}
