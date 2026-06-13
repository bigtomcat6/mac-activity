import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class ActiveCleanupModelTests: XCTestCase {
    func testRefreshLoadsTrashMemoryAndTwentyApps() async {
        let trash = TrashCleanupServiceRecorder(scanResults: [.cleanable(bytes: 4_096, itemCount: 2)])
        let memory = MemoryReleaseServiceRecorder(currentReadings: [MemoryReading(usedBytes: 6, totalBytes: 10)])
        let apps = ActiveAppProviderRecorder(entries: Self.entries(count: 25))
        let model = ActiveCleanupModel(trashService: trash, memoryService: memory, appProvider: apps)

        await model.refresh()

        XCTAssertEqual(model.trashState, .cleanable(bytes: 4_096, itemCount: 2))
        XCTAssertEqual(model.memoryState, .usage(percent: 60, releasableBytes: 0))
        XCTAssertEqual(model.apps.count, 20)
    }

    func testRefreshVisibleCleanReleaseSectionsScansDiskCleanupAndSkipsMemoryEstimate() async {
        let trash = TrashCleanupServiceRecorder(scanResults: [.cleanable(bytes: 4_096, itemCount: 2)])
        let disk = DiskCleanupServiceRecorder(scanResults: [
            .cleanable(summary: Self.diskSummary(bytes: 4_096, itemCount: 2, categoryCount: 1)),
        ])
        let memory = MemoryReleaseServiceRecorder(currentReadings: [
            MemoryReading(
                usedBytes: 6,
                totalBytes: 10,
                breakdown: MemoryBreakdown(cachedBytes: 2)
            )
        ], releasableByteResults: [1])
        let apps = ActiveAppProviderRecorder(entries: Self.entries(count: 2))
        let model = ActiveCleanupModel(
            trashService: trash,
            memoryService: memory,
            diskCleanupService: disk,
            appProvider: apps
        )

        await model.refreshVisibleCleanReleaseSections()

        XCTAssertEqual(model.trashState, .idle)
        XCTAssertEqual(trash.scanCallCount, 0)
        XCTAssertEqual(model.diskCleanupState, .cleanable(bytes: 4_096, itemCount: 2, categories: [.userCaches]))
        XCTAssertEqual(disk.scanCallCount, 1)
        XCTAssertEqual(memory.currentReadingCallCount, 0)
        XCTAssertEqual(memory.releasableBytesCallCount, 0)
        XCTAssertEqual(model.apps.count, 2)
    }

    func testDefaultDiskCleanupOnlyScansAndCleansUserCaches() async {
        let disk = DiskCleanupServiceRecorder(
            scanResults: [.clean, .clean],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
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
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
            diskCleanupService: disk,
            appProvider: ActiveAppProviderRecorder()
        )

        model.setDiskCleanupCategories([.userCaches, .trash, .userLogs])
        await model.refreshDiskCleanup()
        await model.confirmDiskCleanup()

        XCTAssertEqual(disk.scannedCategories, [[.userCaches, .trash, .userLogs], [.userCaches, .trash, .userLogs]])
        XCTAssertEqual(disk.cleanedCategories, [[.userCaches, .trash, .userLogs]])
    }

    func testRefreshMemoryUsageShowsReleaseServiceEstimateInsteadOfCachedMemory() async {
        let memory = MemoryReleaseServiceRecorder(currentReadings: [
            MemoryReading(
                usedBytes: 6,
                totalBytes: 10,
                breakdown: MemoryBreakdown(cachedBytes: 9)
            )
        ], releasableByteResults: [3])
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: memory,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.refreshMemoryUsage()

        XCTAssertEqual(model.memoryState, .usage(percent: 60, releasableBytes: 3))
    }

    func testRequestingTrashCleanupOnlyShowsConfirmation() {
        let trash = TrashCleanupServiceRecorder()
        let model = ActiveCleanupModel(
            trashService: trash,
            memoryService: MemoryReleaseServiceRecorder(),
            appProvider: ActiveAppProviderRecorder()
        )

        model.requestTrashCleanupConfirmation()

        XCTAssertTrue(model.isTrashConfirmationPresented)
        XCTAssertEqual(trash.cleanCallCount, 0)
    }

    func testDuplicateTrashCleanupIsIgnoredUntilPostCleanupRescanFinishes() async {
        let trash = SuspendedTrashCleanupService()
        let model = ActiveCleanupModel(
            trashService: trash,
            memoryService: MemoryReleaseServiceRecorder(),
            appProvider: ActiveAppProviderRecorder()
        )

        async let first: Void = model.confirmTrashCleanup()
        await trash.waitUntilScanStarted()
        await model.confirmTrashCleanup()
        await trash.finishScan(with: .clean)
        await first

        let cleanCallCount = await trash.cleanCallCount()
        XCTAssertEqual(cleanCallCount, 1)
    }

    func testConfirmedTrashCleanupRunsAndReportsCleaned() async {
        let trash = TrashCleanupServiceRecorder(
            scanResults: [.clean],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            trashService: trash,
            memoryService: MemoryReleaseServiceRecorder(),
            appProvider: ActiveAppProviderRecorder()
        )

        await model.confirmTrashCleanup()

        XCTAssertEqual(model.trashState, .cleaned(bytes: 300, itemCount: 1))
        XCTAssertEqual(trash.cleanCallCount, 1)
    }

    func testSuccessfulTrashCleanupRescansAndShowsFreshRemainingTrashIfNeeded() async {
        let trash = TrashCleanupServiceRecorder(
            scanResults: [.cleanable(bytes: 50, itemCount: 1)],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            trashService: trash,
            memoryService: MemoryReleaseServiceRecorder(),
            appProvider: ActiveAppProviderRecorder()
        )

        await model.confirmTrashCleanup()

        XCTAssertEqual(model.trashState, .cleanable(bytes: 50, itemCount: 1))
    }

    func testPartialTrashCleanupRescansRemainingBytes() async {
        let trash = TrashCleanupServiceRecorder(
            scanResults: [.cleanable(bytes: 700, itemCount: 2)],
            cleanResults: [.partial(bytes: 300, deletedCount: 1, failedCount: 1)]
        )
        let model = ActiveCleanupModel(
            trashService: trash,
            memoryService: MemoryReleaseServiceRecorder(),
            appProvider: ActiveAppProviderRecorder()
        )

        await model.confirmTrashCleanup()

        XCTAssertEqual(
            model.trashState,
            .partial(bytes: 300, deletedCount: 1, failedCount: 1, remainingBytes: 700)
        )
    }

    func testConfirmedDiskCleanupRunsAndReportsCleaned() async {
        let disk = DiskCleanupServiceRecorder(
            scanResults: [.clean],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
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
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
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
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
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

    func testReleaseMemoryReportsReleasedResult() async {
        let memory = MemoryReleaseServiceRecorder(releaseResults: [.released(bytes: 1_024, percentOfTotal: 5)])
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: memory,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.releaseMemory()

        XCTAssertEqual(model.memoryState, .released(bytes: 1_024, percentOfTotal: 5))
    }

    func testZeroObservedMemoryReleaseRefreshesUsageInsteadOfShowingReleasedZero() async {
        let memory = MemoryReleaseServiceRecorder(
            currentReadings: [MemoryReading(usedBytes: 5, totalBytes: 10)],
            releasableByteResults: [256],
            releaseResults: [.released(bytes: 0, percentOfTotal: 0)]
        )
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: memory,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.releaseMemory()

        XCTAssertEqual(model.memoryState, .usage(percent: 50, releasableBytes: 256))
    }

    func testNoSignificantMemoryReleaseShowsExplicitState() async {
        let memory = MemoryReleaseServiceRecorder(
            releaseResults: [.noSignificantRelease(observedBytes: 0)]
        )
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: memory,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.releaseMemory()

        XCTAssertEqual(model.memoryState, .noSignificantRelease(observedBytes: 0))
    }

    func testMemoryReleaseCooldownShowsCooldownState() async {
        let memory = MemoryReleaseServiceRecorder(
            releaseResults: [.skippedCooldown(remainingSeconds: 7.5)]
        )
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: memory,
            appProvider: ActiveAppProviderRecorder()
        )

        await model.releaseMemory()

        XCTAssertEqual(model.memoryState, .cooldown(remainingSeconds: 7.5))
    }

    func testDuplicateMemoryReleaseIsIgnoredWhileFirstCallIsRunning() async {
        let memory = SuspendedMemoryReleaseService()
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: memory,
            appProvider: ActiveAppProviderRecorder()
        )

        async let first: Void = model.releaseMemory()
        await memory.waitUntilReleaseStarted()
        await model.releaseMemory()
        await memory.finish(with: .released(bytes: 10, percentOfTotal: 1))
        await first

        let releaseCallCount = await memory.releaseCallCount()
        XCTAssertEqual(releaseCallCount, 1)
    }

    func testQuitMapsRequestedNotFoundAndNotTerminableStates() {
        let app = Self.entries(count: 1)[0]
        let provider = ActiveAppProviderRecorder(
            entries: [app],
            terminationResults: [.requested, .notFound, .notTerminable]
        )
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
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
    }

    func testPendingQuitClearsWhenRefreshedAppsNoLongerContainProcess() {
        let app = Self.entries(count: 1)[0]
        let provider = ActiveAppProviderRecorder(
            entries: [app],
            terminationResults: [.requested]
        )
        let model = ActiveCleanupModel(
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
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
            trashService: TrashCleanupServiceRecorder(),
            memoryService: MemoryReleaseServiceRecorder(),
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
private final class TrashCleanupServiceRecorder: TrashCleanupServicing {
    var scanResults: [TrashScanResult]
    var cleanResults: [TrashCleanupResult]
    private(set) var scanCallCount = 0
    private(set) var cleanCallCount = 0

    init(
        scanResults: [TrashScanResult] = [],
        cleanResults: [TrashCleanupResult] = [.cleaned(bytes: 0, itemCount: 0)]
    ) {
        self.scanResults = scanResults
        self.cleanResults = cleanResults
    }

    func scan() async -> TrashScanResult {
        scanCallCount += 1
        guard scanResults.isEmpty == false else { return .clean }
        return scanResults.removeFirst()
    }

    func clean() async -> TrashCleanupResult {
        cleanCallCount += 1
        guard cleanResults.isEmpty == false else { return .cleaned(bytes: 0, itemCount: 0) }
        return cleanResults.removeFirst()
    }
}

@MainActor
private final class MemoryReleaseServiceRecorder: MemoryReleaseServicing {
    var currentReadings: [MemoryReading]
    var releasableByteResults: [UInt64?]
    var releaseResults: [MemoryReleaseResult]
    private(set) var releaseCallCount = 0
    private(set) var currentReadingCallCount = 0
    private(set) var releasableBytesCallCount = 0

    init(
        currentReadings: [MemoryReading] = [],
        releasableByteResults: [UInt64?] = [],
        releaseResults: [MemoryReleaseResult] = [.unavailable]
    ) {
        self.currentReadings = currentReadings
        self.releasableByteResults = releasableByteResults
        self.releaseResults = releaseResults
    }

    func currentReading() async -> MemoryReading? {
        currentReadingCallCount += 1
        guard currentReadings.isEmpty == false else { return nil }
        return currentReadings.removeFirst()
    }

    func release() async -> MemoryReleaseResult {
        releaseCallCount += 1
        guard releaseResults.isEmpty == false else { return .unavailable }
        return releaseResults.removeFirst()
    }

    func currentReleasableBytes() async -> UInt64? {
        releasableBytesCallCount += 1
        guard releasableByteResults.isEmpty == false else { return nil }
        return releasableByteResults.removeFirst()
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
private final class SuspendedTrashCleanupService: TrashCleanupServicing {
    private var scanContinuation: CheckedContinuation<TrashScanResult, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var cleanCalls = 0

    func clean() async -> TrashCleanupResult {
        cleanCalls += 1
        return .cleaned(bytes: 1, itemCount: 1)
    }

    func scan() async -> TrashScanResult {
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { scanContinuation = $0 }
    }

    func waitUntilScanStarted() async {
        if scanContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finishScan(with result: TrashScanResult) async {
        scanContinuation?.resume(returning: result)
        scanContinuation = nil
    }

    func cleanCallCount() async -> Int { cleanCalls }
}

@MainActor
private final class SuspendedMemoryReleaseService: MemoryReleaseServicing {
    private var continuation: CheckedContinuation<MemoryReleaseResult, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func currentReading() async -> MemoryReading? { nil }

    func currentReleasableBytes() async -> UInt64? { nil }

    func release() async -> MemoryReleaseResult {
        calls += 1
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilReleaseStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finish(with result: MemoryReleaseResult) async {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func releaseCallCount() async -> Int { calls }
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

    func requestTermination(processIdentifier: pid_t) -> ActiveAppTerminationResult {
        guard terminationResults.isEmpty == false else { return .notFound }
        return terminationResults.removeFirst()
    }
}
