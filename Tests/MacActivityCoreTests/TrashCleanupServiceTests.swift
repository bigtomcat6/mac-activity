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
        let ok = trashURL.appendingPathComponent("ok.tmp")
        let blocked = trashURL.appendingPathComponent("blocked.tmp")
        let filesystem = TrashFilesystemRecorder(
            contents: [trashURL: [ok, blocked]],
            allocatedSizes: [ok: 100, blocked: 200],
            removeFailures: [blocked: TestTrashError.denied]
        )
        let service = TrashCleanupService(trashDirectory: trashURL, filesystem: filesystem)

        let result = await service.clean()

        XCTAssertEqual(result, .partial(bytes: 100, deletedCount: 1, failedCount: 1))
        XCTAssertEqual(filesystem.removedItems(), [ok, blocked])
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

        XCTAssertEqual(result, .failed("Unable to delete Trash items."))
        XCTAssertEqual(filesystem.removedItems(), [blocked])
    }
}

private enum TestTrashError: Error, LocalizedError {
    case denied

    var errorDescription: String? { "denied" }
}

private final class TrashFilesystemRecorder: TrashFilesystem, @unchecked Sendable {
    var contents: [URL: [URL]]
    var allocatedSizes: [URL: UInt64]
    var contentsFailures: [URL: Error]
    var removeFailures: [URL: Error]

    private var removed: [URL] = []

    init(
        contents: [URL: [URL]] = [:],
        allocatedSizes: [URL: UInt64] = [:],
        contentsFailures: [URL: Error] = [:],
        removeFailures: [URL: Error] = [:]
    ) {
        self.contents = contents
        self.allocatedSizes = allocatedSizes
        self.contentsFailures = contentsFailures
        self.removeFailures = removeFailures
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        if let error = contentsFailures[url] { throw error }
        return contents[url] ?? []
    }

    func allocatedSizeOfItem(at url: URL) throws -> UInt64 {
        allocatedSizes[url] ?? 0
    }

    func removeItem(at url: URL) throws {
        removed.append(url)
        if let error = removeFailures[url] { throw error }
    }

    func removedItems() -> [URL] {
        removed
    }
}
