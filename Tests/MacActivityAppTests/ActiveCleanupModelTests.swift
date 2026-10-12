import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class ActiveCleanupModelTests: XCTestCase {
    func testRefreshVisibleCleanReleaseSectionsScansDiskCleanupAndApps() async {
        let disk = DiskCleanupServiceRecorder(scanResults: [
            .cleanable(summary: Self.diskSummary(bytes: 4_096, itemCount: 2, categoryCount: 1))
        ])
        let apps = ActiveAppProviderRecorder(entries: Self.entries(count: 2))
        let model = ActiveCleanupModel(diskCleanupService: disk, appProvider: apps)

        await model.refreshVisibleCleanReleaseSections()

        XCTAssertEqual(model.diskCleanupState, .cleanable(bytes: 4_096, itemCount: 2, categories: [.userCaches]))
        XCTAssertEqual(disk.scanCallCount, 1)
        XCTAssertEqual(model.apps.count, 2)
    }

    func testDefaultDiskCleanupOnlyScansAndCleansUserCaches() async {
        let disk = DiskCleanupServiceRecorder(
            scanResults: [.clean, .clean],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            diskCleanupService: disk,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.refreshDiskCleanup()
        await model.confirmDiskCleanup()

        XCTAssertEqual(disk.scannedCategories, [[.userCaches], [.userCaches]])
        XCTAssertEqual(disk.cleanedCategories, [[.userCaches]])
    }

    func testDiskCleanupCategoriesCanIncludeCachesTrashAndLogs() async {
        let disk = DiskCleanupServiceRecorder(
            scanResults: [.clean, .clean],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            diskCleanupService: disk,
            appProvider: ActiveAppProviderRecorder()
        )

        model.setDiskCleanupCategories([.userCaches, .trash, .userLogs])
        await model.refreshDiskCleanup()
        await model.confirmDiskCleanup()

        XCTAssertEqual(disk.scannedCategories, [[.userCaches, .trash, .userLogs], [.userCaches, .trash, .userLogs]])
        XCTAssertEqual(disk.cleanedCategories, [[.userCaches, .trash, .userLogs]])
    }

    func testConfirmedDiskCleanupRunsAndReportsCleaned() async {
        let disk = DiskCleanupServiceRecorder(
            scanResults: [.clean],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            diskCleanupService: disk,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.confirmDiskCleanup()

        XCTAssertEqual(model.diskCleanupState, .cleaned(bytes: 300, itemCount: 1))
        XCTAssertEqual(disk.cleanCallCount, 1)
    }

    func testPartialDiskCleanupRescansRemainingBytes() async {
        let disk = DiskCleanupServiceRecorder(
            scanResults: [.cleanable(summary: Self.diskSummary(bytes: 700, itemCount: 2, categoryCount: 1))],
            cleanResults: [.partial(bytes: 300, deletedCount: 1, failedCount: 1, remainingBytes: 200)]
        )
        let model = ActiveCleanupModel(
            diskCleanupService: disk,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.confirmDiskCleanup()

        XCTAssertEqual(
            model.diskCleanupState,
            .partial(bytes: 300, deletedCount: 1, failedCount: 1, remainingBytes: 700)
        )
    }

    func testDuplicateDiskCleanupIsIgnoredUntilPostCleanupRescanFinishes() async {
        let disk = SuspendedDiskCleanupService()
        let model = ActiveCleanupModel(
            diskCleanupService: disk,
            appProvider: ActiveAppProviderRecorder()
        )

        async let first: Void = model.confirmDiskCleanup()
        await disk.waitUntilScanStarted()
        await model.confirmDiskCleanup()
        await disk.finishScan(with: .clean)
        await first

        let cleanCallCount = await disk.cleanCallCount()
        XCTAssertEqual(cleanCallCount, 1)
    }

    func testDiskCleanupScanFailuresPropagateThroughRefreshAndPostCleanupRescan() async {
        let disk = DiskCleanupServiceRecorder(
            scanResults: [
                .failed("scan denied"),
                .failed("rescan denied")
            ],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            diskCleanupService: disk,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.refreshDiskCleanup()
        XCTAssertEqual(model.diskCleanupState, .failed(.message("scan denied")))

        await model.confirmDiskCleanup()
        XCTAssertEqual(model.diskCleanupState, .failed(.message("rescan denied")))
    }

    func testQuitMapsRequestedNotFoundAndNotTerminableStates() {
        let app = Self.entries(count: 1)[0]
        let provider = ActiveAppProviderRecorder(
            entries: [app],
            terminationResults: [.requested, .notFound, .notTerminable]
        )
        let model = ActiveCleanupModel(
            appProvider: provider
        )

        model.quit(app)
        XCTAssertEqual(model.processActionState, .requested(app.name))
        XCTAssertTrue(model.isQuitPending(for: app.processIdentifier))
        model.quit(app)
        XCTAssertEqual(model.processActionState, .notFound(app.name))
        XCTAssertFalse(model.isQuitPending(for: app.processIdentifier))
        model.quit(app)
        XCTAssertEqual(model.processActionState, .notTerminable(app.name))
        XCTAssertFalse(model.isQuitPending(for: app.processIdentifier))
        XCTAssertEqual(provider.terminationRequests, [app, app, app])
    }

    func testPendingQuitClearsWhenRefreshedAppsNoLongerContainProcess() {
        let app = Self.entries(count: 1)[0]
        let provider = ActiveAppProviderRecorder(
            entries: [app],
            terminationResults: [.requested]
        )
        let model = ActiveCleanupModel(
            appProvider: provider
        )

        model.refreshApps()
        model.quit(app)

        XCTAssertTrue(model.isQuitPending(for: app.processIdentifier))

        provider.entries = []
        model.refreshApps()

        XCTAssertFalse(model.isQuitPending(for: app.processIdentifier))
        XCTAssertTrue(model.apps.isEmpty)
    }

    func testPendingQuitRefreshLoopStopsWhenAppDisappears() async {
        let app = Self.entries(count: 1)[0]
        let provider = ActiveAppProviderRecorder(
            entriesByCall: [[app], [app], []],
            terminationResults: [.requested]
        )
        let model = ActiveCleanupModel(
            appProvider: provider,
            quitRefreshIntervalNanoseconds: 0,
            quitRefreshAttemptLimit: 3
        )

        model.refreshApps()
        model.quit(app)

        XCTAssertTrue(model.isQuitPending(for: app.processIdentifier))

        await model.refreshQuittingProcessesUntilResolved()

        XCTAssertFalse(model.isQuitPending(for: app.processIdentifier))
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertEqual(provider.topAppsCallCount, 3)
    }

    static func entries(count: Int) -> [ActiveAppMemoryEntry] {
        (0..<count).map { index in
            ActiveAppMemoryEntry(
                processIdentifier: pid_t(1_000 + index),
                name: "App \(index)",
                bundleIdentifier: "com.example.app\(index)",
                residentMemoryBytes: UInt64((count - index) * 1_000),
                isTerminable: true
            )
        }
    }

    static func diskSummary(bytes: UInt64, itemCount: Int, categoryCount: Int) -> DiskCleanupSummary {
        let categories = (0..<categoryCount).map { index in
            DiskCleanupCategorySummary(
                kind: index == 0 ? .trash : .userCaches,
                titleKey: index == 0 ? "trash" : "userCaches",
                totalBytes: bytes,
                selectedBytes: bytes,
                itemCount: itemCount,
                selectedItemCount: itemCount,
                accessIssueCount: 0
            )
        }
        let candidates = (0..<itemCount).map { index in
            DiskCleanupCandidate(
                url: URL(fileURLWithPath: "/Users/test/.Trash/item-\(index)"),
                kind: .trash,
                allocatedBytes: itemCount == 0 ? 0 : bytes / UInt64(itemCount),
                deletionMode: .deleteImmediately,
                reason: "test"
            )
        }
        return DiskCleanupSummary(
            totalBytes: bytes,
            selectedBytes: bytes,
            itemCount: itemCount,
            selectedItemCount: itemCount,
            accessIssueCount: 0,
            categories: categories,
            candidates: candidates,
            accessIssues: []
        )
    }
}

@MainActor
private final class DiskCleanupServiceRecorder: DiskCleanupServicing {
    var scanResults: [DiskCleanupScanResult]
    var cleanResults: [DiskCleanupResult]
    private(set) var scanCallCount = 0
    private(set) var cleanCallCount = 0
    private(set) var scannedCategories: [[DiskCleanupCategoryKind]] = []
    private(set) var cleanedCategories: [[DiskCleanupCategoryKind]] = []

    init(
        scanResults: [DiskCleanupScanResult] = [],
        cleanResults: [DiskCleanupResult] = [.cleaned(bytes: 0, itemCount: 0)]
    ) {
        self.scanResults = scanResults
        self.cleanResults = cleanResults
    }

    func scan(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupScanResult {
        scanCallCount += 1
        scannedCategories.append(categories)
        guard scanResults.isEmpty == false else { return .clean }
        return scanResults.removeFirst()
    }

    func clean(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupResult {
        cleanCallCount += 1
        cleanedCategories.append(categories)
        guard cleanResults.isEmpty == false else { return .cleaned(bytes: 0, itemCount: 0) }
        return cleanResults.removeFirst()
    }
}

@MainActor
private final class SuspendedDiskCleanupService: DiskCleanupServicing {
    private var scanContinuation: CheckedContinuation<DiskCleanupScanResult, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var cleanCalls = 0

    func clean(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupResult {
        cleanCalls += 1
        return .cleaned(bytes: 1, itemCount: 1)
    }

    func scan(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupScanResult {
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { scanContinuation = $0 }
    }

    func waitUntilScanStarted() async {
        if scanContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finishScan(with result: DiskCleanupScanResult) async {
        scanContinuation?.resume(returning: result)
        scanContinuation = nil
    }

    func cleanCallCount() async -> Int { cleanCalls }
}

@MainActor
private final class ActiveAppProviderRecorder: ActiveAppMemoryProviding {
    var entries: [ActiveAppMemoryEntry]
    var entriesByCall: [[ActiveAppMemoryEntry]]
    var terminationResults: [ActiveAppTerminationResult]
    private(set) var terminationRequests: [ActiveAppMemoryEntry] = []
    private(set) var topAppsCallCount = 0

    init(
        entries: [ActiveAppMemoryEntry] = [],
        entriesByCall: [[ActiveAppMemoryEntry]] = [],
        terminationResults: [ActiveAppTerminationResult] = []
    ) {
        self.entries = entries
        self.entriesByCall = entriesByCall
        self.terminationResults = terminationResults
    }

    func topApps(limit: Int) -> [ActiveAppMemoryEntry] {
        topAppsCallCount += 1
        if entriesByCall.isEmpty == false {
            entries = entriesByCall.removeFirst()
        }
        return Array(entries.prefix(limit))
    }

    func requestTermination(_ app: ActiveAppMemoryEntry) -> ActiveAppTerminationResult {
        terminationRequests.append(app)
        guard terminationResults.isEmpty == false else { return .notFound }
        return terminationResults.removeFirst()
    }
}
