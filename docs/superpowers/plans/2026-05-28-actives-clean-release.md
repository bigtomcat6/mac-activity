# Actives Clean Release Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Actives tab content with a Lemon Cleaner-style clean-release page covering Trash cleanup, memory release, foreground app memory bars, and polite quit requests.

**Architecture:** Put system-facing cleanup behavior in `MacActivityCore`, and keep all Actives page state and SwiftUI rendering in `MacActivityApp`. The existing dashboard shell keeps the tab picker, footer, and app-level actions; it only hosts `ActiveCleanReleaseView` for the Actives tab. All filesystem, memory, and process behavior is behind injectable protocols so tests never delete real files or quit real apps.

**Tech Stack:** Swift 6.0, SwiftUI, AppKit `NSRunningApplication`, Foundation `FileManager` and `URLResourceValues`, XCTest, SwiftPM, XcodeGen.

---

## Chunk 1: Core Cleanup Services

### Task 1: Trash Cleanup Service

**Files:**
- Create: `Sources/MacActivityCore/Cleanup/TrashCleanupService.swift`
- Create: `Tests/MacActivityCoreTests/TrashCleanupServiceTests.swift`
- Later sync: `MacActivity.xcodeproj/project.pbxproj` via Task 7

- [ ] **Step 1: Write the failing Trash tests**

Create `Tests/MacActivityCoreTests/TrashCleanupServiceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run Trash tests to verify RED**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter TrashCleanupServiceTests
```

Expected: compile failure because `TrashCleanupService`, `TrashScanResult`, `TrashCleanupResult`, and `TrashFilesystem` do not exist.

- [ ] **Step 3: Implement Trash cleanup**

Create `Sources/MacActivityCore/Cleanup/TrashCleanupService.swift`:

```swift
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
            includingPropertiesForKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: []
        )
    }

    public func allocatedSizeOfItem(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        var total = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
        guard values.isDirectory == true else { return total }

        let children = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: []
        )
        while let child = children?.nextObject() as? URL {
            let childValues = try? child.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
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
        trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true),
        filesystem: any TrashFilesystem = LiveTrashFilesystem()
    ) {
        self.trashDirectory = trashDirectory
        self.filesystem = filesystem
    }

    public func scan() async -> TrashScanResult {
        do {
            let children = try filesystem.contentsOfDirectory(at: trashDirectory)
            let total = children.reduce(UInt64(0)) { partial, url in
                partial + ((try? filesystem.allocatedSizeOfItem(at: url)) ?? 0)
            }
            return total == 0 ? .clean : .cleanable(bytes: total, itemCount: children.count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func clean() async -> TrashCleanupResult {
        do {
            let children = try filesystem.contentsOfDirectory(at: trashDirectory)
            guard children.isEmpty == false else { return .cleaned(bytes: 0, itemCount: 0) }

            var deletedBytes = UInt64(0)
            var deletedCount = 0
            var failedCount = 0

            for child in children {
                let size = (try? filesystem.allocatedSizeOfItem(at: child)) ?? 0
                do {
                    try filesystem.removeItem(at: child)
                    deletedBytes += size
                    deletedCount += 1
                } catch {
                    failedCount += 1
                }
            }

            if deletedCount == 0 {
                return .failed("Unable to delete Trash items.")
            }
            if failedCount > 0 {
                return .partial(bytes: deletedBytes, deletedCount: deletedCount, failedCount: failedCount)
            }
            return .cleaned(bytes: deletedBytes, itemCount: deletedCount)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run Trash tests to verify GREEN**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter TrashCleanupServiceTests
```

Expected: all `TrashCleanupServiceTests` pass.

- [ ] **Step 5: Commit Trash cleanup**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git add Sources/MacActivityCore/Cleanup/TrashCleanupService.swift Tests/MacActivityCoreTests/TrashCleanupServiceTests.swift
cd /Users/how/Git/How/How/MacActivity/mac-activity && git commit -m "feat: add trash cleanup service"
```

Expected: commit succeeds with only the two Trash files.

### Task 2: Memory Release Service

**Files:**
- Create: `Sources/MacActivityCore/Cleanup/MemoryReleaseService.swift`
- Create: `Tests/MacActivityCoreTests/MemoryReleaseServiceTests.swift`
- Later sync: `MacActivity.xcodeproj/project.pbxproj` via Task 7

- [ ] **Step 1: Write the failing Memory tests**

Create `Tests/MacActivityCoreTests/MemoryReleaseServiceTests.swift`:

```swift
import XCTest
@testable import MacActivityCore

final class MemoryReleaseServiceTests: XCTestCase {
    func testReleaseComputesReclaimedBytesAndPercent() async {
        let reader = MemoryReadingRecorder(readings: [
            MemoryReading(usedBytes: 8_000, totalBytes: 10_000),
            MemoryReading(usedBytes: 6_500, totalBytes: 10_000)
        ])
        let cleaner = MemoryCleanerRecorder(results: [.succeeded])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.release()

        XCTAssertEqual(result, .released(bytes: 1_500, percentOfTotal: 15))
        XCTAssertEqual(await cleaner.callCount(), 1)
    }

    func testReleaseFloorsNegativeReclaimedBytesToZero() async {
        let reader = MemoryReadingRecorder(readings: [
            MemoryReading(usedBytes: 6_000, totalBytes: 10_000),
            MemoryReading(usedBytes: 7_000, totalBytes: 10_000)
        ])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: MemoryCleanerRecorder(results: [.succeeded]))

        let result = await service.release()

        XCTAssertEqual(result, .released(bytes: 0, percentOfTotal: 0))
    }

    func testReleasePropagatesUnavailable() async {
        let reader = MemoryReadingRecorder(readings: [MemoryReading(usedBytes: 8, totalBytes: 10)])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: MemoryCleanerRecorder(results: [.unavailable]))

        let result = await service.release()

        XCTAssertEqual(result, .unavailable)
    }

    func testReleasePropagatesFailedExitCode() async {
        let reader = MemoryReadingRecorder(readings: [MemoryReading(usedBytes: 8, totalBytes: 10)])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: MemoryCleanerRecorder(results: [.failed(exitCode: 9)]))

        let result = await service.release()

        XCTAssertEqual(result, .failed(exitCode: 9))
    }

    func testReleaseReportsFailedToReadMemoryWhenBeforeReadingIsMissing() async {
        let service = MemoryReleaseService(
            memoryReader: MemoryReadingRecorder(readings: []),
            cleaner: MemoryCleanerRecorder(results: [.succeeded])
        )

        let result = await service.release()

        XCTAssertEqual(result, .failedToReadMemory)
    }

    func testReleaseReportsFailedToReadMemoryWhenAfterReadingIsMissing() async {
        let service = MemoryReleaseService(
            memoryReader: MemoryReadingRecorder(readings: [MemoryReading(usedBytes: 8, totalBytes: 10)]),
            cleaner: MemoryCleanerRecorder(results: [.succeeded])
        )

        let result = await service.release()

        XCTAssertEqual(result, .failedToReadMemory)
    }

    func testCurrentReadingReturnsReaderValue() async {
        let reading = MemoryReading(usedBytes: 5, totalBytes: 10)
        let service = MemoryReleaseService(
            memoryReader: MemoryReadingRecorder(readings: [reading]),
            cleaner: MemoryCleanerRecorder(results: [])
        )

        let result = await service.currentReading()

        XCTAssertEqual(result, reading)
    }
}

private actor MemoryReadingRecorder: MemoryReadingProviding {
    private var readings: [MemoryReading]

    init(readings: [MemoryReading]) {
        self.readings = readings
    }

    func memoryReading() async -> MemoryReading? {
        guard readings.isEmpty == false else { return nil }
        return readings.removeFirst()
    }
}

private actor MemoryCleanerRecorder: MemoryCleaning {
    private var results: [CleanMemoryResult]
    private var calls = 0

    init(results: [CleanMemoryResult]) {
        self.results = results
    }

    func cleanMemory() async -> CleanMemoryResult {
        calls += 1
        guard results.isEmpty == false else { return .unavailable }
        return results.removeFirst()
    }

    func callCount() -> Int {
        calls
    }
}
```

- [ ] **Step 2: Run Memory tests to verify RED**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter MemoryReleaseServiceTests
```

Expected: compile failure because `MemoryReleaseService`, `MemoryReleaseResult`, and `MemoryReadingProviding` do not exist.

- [ ] **Step 3: Implement Memory release**

Create `Sources/MacActivityCore/Cleanup/MemoryReleaseService.swift`:

```swift
import Foundation

public protocol MemoryReadingProviding: Sendable {
    func memoryReading() async -> MemoryReading?
}

public struct LiveMemoryReadingProvider: MemoryReadingProviding {
    private let provider: MemoryProvider

    public init(provider: MemoryProvider = MemoryProvider()) {
        self.provider = provider
    }

    public func memoryReading() async -> MemoryReading? {
        switch await provider.sample() {
        case .memory(let reading):
            return reading
        default:
            return nil
        }
    }
}

public enum MemoryReleaseResult: Equatable, Sendable {
    case released(bytes: UInt64, percentOfTotal: Double)
    case unavailable
    case failed(exitCode: Int32)
    case failedToReadMemory
}

public struct MemoryReleaseService: Sendable {
    private let memoryReader: any MemoryReadingProviding
    private let cleaner: any MemoryCleaning

    public init(
        memoryReader: any MemoryReadingProviding = LiveMemoryReadingProvider(),
        cleaner: any MemoryCleaning = CleanMemoryService()
    ) {
        self.memoryReader = memoryReader
        self.cleaner = cleaner
    }

    public func currentReading() async -> MemoryReading? {
        await memoryReader.memoryReading()
    }

    public func release() async -> MemoryReleaseResult {
        guard let before = await memoryReader.memoryReading() else {
            return .failedToReadMemory
        }

        switch await cleaner.cleanMemory() {
        case .succeeded:
            guard let after = await memoryReader.memoryReading() else {
                return .failedToReadMemory
            }
            let reclaimed = before.usedBytes > after.usedBytes ? before.usedBytes - after.usedBytes : 0
            let percent = before.totalBytes > 0 ? Double(reclaimed) / Double(before.totalBytes) * 100 : 0
            return .released(bytes: reclaimed, percentOfTotal: percent)
        case .unavailable:
            return .unavailable
        case .failed(let exitCode):
            return .failed(exitCode: exitCode)
        }
    }
}
```

- [ ] **Step 4: Run Memory tests to verify GREEN**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter MemoryReleaseServiceTests
```

Expected: all `MemoryReleaseServiceTests` pass.

- [ ] **Step 5: Commit Memory release**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git add Sources/MacActivityCore/Cleanup/MemoryReleaseService.swift Tests/MacActivityCoreTests/MemoryReleaseServiceTests.swift
cd /Users/how/Git/How/How/MacActivity/mac-activity && git commit -m "feat: add memory release service"
```

Expected: commit succeeds with only the two Memory release files.

### Task 3: Active App Provider Protocol and Bar Math

**Files:**
- Create: `Sources/MacActivityCore/Cleanup/ActiveAppMemoryProviding.swift`
- Create: `Tests/MacActivityCoreTests/ActiveAppMemoryProvidingTests.swift`
- Create: `Sources/MacActivityApp/Views/ActiveProcessMemoryLayout.swift`
- Create: `Tests/MacActivityAppTests/ActiveProcessMemoryLayoutTests.swift`
- Later sync: `MacActivity.xcodeproj/project.pbxproj` via Task 7

- [ ] **Step 1: Write provider and layout tests**

Create `Tests/MacActivityCoreTests/ActiveAppMemoryProvidingTests.swift`:

```swift
import XCTest
@testable import MacActivityCore

final class ActiveAppMemoryProvidingTests: XCTestCase {
    @MainActor
    func testActiveAppMemoryServiceConformsToProviderProtocol() {
        let provider: any ActiveAppMemoryProviding = ActiveAppMemoryService()
        XCTAssertTrue(type(of: provider) == ActiveAppMemoryService.self)
    }
}
```

Create `Tests/MacActivityAppTests/ActiveProcessMemoryLayoutTests.swift`:

```swift
import XCTest
@testable import MacActivityApp

final class ActiveProcessMemoryLayoutTests: XCTestCase {
    func testRowProgressScalesAgainstLargestVisibleProcess() {
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 50, maxBytes: 100), 0.5)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 150, maxBytes: 100), 1.0)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 0, maxBytes: 100), 0.0)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 10, maxBytes: 0), 0.0)
    }

    func testCompactLayoutConstantsMatchCleanReleasePage() {
        XCTAssertEqual(ActiveProcessMemoryLayout.rowHeight, 38)
        XCTAssertEqual(ActiveProcessMemoryLayout.trailingActionWidth, 72)
    }
}
```

- [ ] **Step 2: Run provider and layout tests to verify RED**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveAppMemoryProvidingTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveProcessMemoryLayoutTests
```

Expected: compile failure because `ActiveAppMemoryProviding` and `ActiveProcessMemoryLayout` do not exist.

- [ ] **Step 3: Implement provider protocol and bar math**

Create `Sources/MacActivityCore/Cleanup/ActiveAppMemoryProviding.swift`:

```swift
import Foundation

@MainActor
public protocol ActiveAppMemoryProviding: AnyObject {
    func topApps(limit: Int) -> [ActiveAppMemoryEntry]
    func requestTermination(processIdentifier: pid_t) -> ActiveAppTerminationResult
}

extension ActiveAppMemoryService: ActiveAppMemoryProviding {}
```

Create `Sources/MacActivityApp/Views/ActiveProcessMemoryLayout.swift`:

```swift
import Foundation

enum ActiveProcessMemoryLayout {
    static let rowHeight: CGFloat = 38
    static let trailingActionWidth: CGFloat = 72

    static func progress(bytes: UInt64, maxBytes: UInt64) -> Double {
        guard maxBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(maxBytes)))
    }
}
```

- [ ] **Step 4: Run provider and layout tests to verify GREEN**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveAppMemoryProvidingTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveProcessMemoryLayoutTests
```

Expected: both test filters pass.

- [ ] **Step 5: Commit provider and layout math**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git add Sources/MacActivityCore/Cleanup/ActiveAppMemoryProviding.swift Tests/MacActivityCoreTests/ActiveAppMemoryProvidingTests.swift Sources/MacActivityApp/Views/ActiveProcessMemoryLayout.swift Tests/MacActivityAppTests/ActiveProcessMemoryLayoutTests.swift
cd /Users/how/Git/How/How/MacActivity/mac-activity && git commit -m "feat: add actives process memory layout"
```

Expected: commit succeeds with the four listed files.

## Chunk 2: Actives Model

### Task 4: Active Cleanup Model

**Files:**
- Create: `Sources/MacActivityApp/Models/ActiveCleanupModel.swift`
- Create: `Tests/MacActivityAppTests/ActiveCleanupModelTests.swift`

- [ ] **Step 1: Write model tests**

Create `Tests/MacActivityAppTests/ActiveCleanupModelTests.swift`:

```swift
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
        XCTAssertEqual(model.memoryState, .usage(percent: 60))
        XCTAssertEqual(model.apps.count, 20)
    }

    func testRequestingTrashCleanupOnlyShowsConfirmation() {
        let trash = TrashCleanupServiceRecorder()
        let model = ActiveCleanupModel(trashService: trash, memoryService: MemoryReleaseServiceRecorder(), appProvider: ActiveAppProviderRecorder())

        model.requestTrashCleanupConfirmation()

        XCTAssertTrue(model.isTrashConfirmationPresented)
        XCTAssertEqual(trash.cleanCallCount, 0)
    }

    func testDuplicateTrashCleanupIsIgnoredUntilPostCleanupRescanFinishes() async {
        let trash = SuspendedTrashCleanupService()
        let model = ActiveCleanupModel(trashService: trash, memoryService: MemoryReleaseServiceRecorder(), appProvider: ActiveAppProviderRecorder())

        async let first: Void = model.confirmTrashCleanup()
        await trash.waitUntilScanStarted()
        await model.confirmTrashCleanup()
        await trash.finishScan(with: .clean)
        await first

        XCTAssertEqual(await trash.cleanCallCount(), 1)
    }

    func testConfirmedTrashCleanupRunsAndReportsCleaned() async {
        let trash = TrashCleanupServiceRecorder(cleanResults: [.cleaned(bytes: 300, itemCount: 1)])
        let model = ActiveCleanupModel(trashService: trash, memoryService: MemoryReleaseServiceRecorder(), appProvider: ActiveAppProviderRecorder())

        await model.confirmTrashCleanup()

        XCTAssertEqual(model.trashState, .cleaned(bytes: 300, itemCount: 1))
        XCTAssertEqual(trash.cleanCallCount, 1)
    }

    func testSuccessfulTrashCleanupRescansAndShowsFreshRemainingTrashIfNeeded() async {
        let trash = TrashCleanupServiceRecorder(
            scanResults: [.cleanable(bytes: 50, itemCount: 1)],
            cleanResults: [.cleaned(bytes: 300, itemCount: 1)]
        )
        let model = ActiveCleanupModel(trashService: trash, memoryService: MemoryReleaseServiceRecorder(), appProvider: ActiveAppProviderRecorder())

        await model.confirmTrashCleanup()

        XCTAssertEqual(model.trashState, .cleanable(bytes: 50, itemCount: 1))
    }

    func testPartialTrashCleanupRescansRemainingBytes() async {
        let trash = TrashCleanupServiceRecorder(
            scanResults: [.cleanable(bytes: 700, itemCount: 2)],
            cleanResults: [.partial(bytes: 300, deletedCount: 1, failedCount: 1)]
        )
        let model = ActiveCleanupModel(trashService: trash, memoryService: MemoryReleaseServiceRecorder(), appProvider: ActiveAppProviderRecorder())

        await model.confirmTrashCleanup()

        XCTAssertEqual(model.trashState, .partial(bytes: 300, deletedCount: 1, failedCount: 1, remainingBytes: 700))
    }

    func testReleaseMemoryReportsReleasedResult() async {
        let memory = MemoryReleaseServiceRecorder(releaseResults: [.released(bytes: 1_024, percentOfTotal: 5)])
        let model = ActiveCleanupModel(trashService: TrashCleanupServiceRecorder(), memoryService: memory, appProvider: ActiveAppProviderRecorder())

        await model.releaseMemory()

        XCTAssertEqual(model.memoryState, .released(bytes: 1_024, percentOfTotal: 5))
    }

    func testDuplicateMemoryReleaseIsIgnoredWhileFirstCallIsRunning() async {
        let memory = SuspendedMemoryReleaseService()
        let model = ActiveCleanupModel(trashService: TrashCleanupServiceRecorder(), memoryService: memory, appProvider: ActiveAppProviderRecorder())

        async let first: Void = model.releaseMemory()
        await memory.waitUntilReleaseStarted()
        await model.releaseMemory()
        await memory.finish(with: .released(bytes: 10, percentOfTotal: 1))
        await first

        XCTAssertEqual(await memory.releaseCallCount(), 1)
    }

    func testQuitMapsRequestedNotFoundAndNotTerminableStates() {
        let app = Self.entries(count: 1)[0]
        let provider = ActiveAppProviderRecorder(entries: [app], terminationResults: [.requested, .notFound, .notTerminable])
        let model = ActiveCleanupModel(trashService: TrashCleanupServiceRecorder(), memoryService: MemoryReleaseServiceRecorder(), appProvider: provider)

        model.quit(app)
        XCTAssertEqual(model.processActionState, .requested(app.name))
        model.quit(app)
        XCTAssertEqual(model.processActionState, .notFound(app.name))
        model.quit(app)
        XCTAssertEqual(model.processActionState, .notTerminable(app.name))
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
}

@MainActor
private final class TrashCleanupServiceRecorder: TrashCleanupServicing {
    var scanResults: [TrashScanResult]
    var cleanResults: [TrashCleanupResult]
    private(set) var cleanCallCount = 0

    init(scanResults: [TrashScanResult] = [.clean], cleanResults: [TrashCleanupResult] = [.cleaned(bytes: 0, itemCount: 0)]) {
        self.scanResults = scanResults
        self.cleanResults = cleanResults
    }

    func scan() async -> TrashScanResult {
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
    var releaseResults: [MemoryReleaseResult]
    private(set) var releaseCallCount = 0

    init(currentReadings: [MemoryReading] = [], releaseResults: [MemoryReleaseResult] = [.unavailable]) {
        self.currentReadings = currentReadings
        self.releaseResults = releaseResults
    }

    func currentReading() async -> MemoryReading? {
        guard currentReadings.isEmpty == false else { return nil }
        return currentReadings.removeFirst()
    }

    func release() async -> MemoryReleaseResult {
        releaseCallCount += 1
        guard releaseResults.isEmpty == false else { return .unavailable }
        return releaseResults.removeFirst()
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
private final class ActiveAppProviderRecorder: ActiveAppMemoryProviding {
    var entries: [ActiveAppMemoryEntry]
    var terminationResults: [ActiveAppTerminationResult]

    init(entries: [ActiveAppMemoryEntry] = [], terminationResults: [ActiveAppTerminationResult] = []) {
        self.entries = entries
        self.terminationResults = terminationResults
    }

    func topApps(limit: Int) -> [ActiveAppMemoryEntry] {
        Array(entries.prefix(limit))
    }

    func requestTermination(processIdentifier: pid_t) -> ActiveAppTerminationResult {
        guard terminationResults.isEmpty == false else { return .notFound }
        return terminationResults.removeFirst()
    }
}
```

- [ ] **Step 2: Run model tests to verify RED**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanupModelTests
```

Expected: compile failure because `ActiveCleanupModel`, `TrashCleanupServicing`, and `MemoryReleaseServicing` do not exist.

- [ ] **Step 3: Implement Active cleanup model**

Create `Sources/MacActivityApp/Models/ActiveCleanupModel.swift`:

```swift
import Foundation
import MacActivityCore

@MainActor
protocol TrashCleanupServicing {
    func scan() async -> TrashScanResult
    func clean() async -> TrashCleanupResult
}

extension TrashCleanupService: TrashCleanupServicing {}

@MainActor
protocol MemoryReleaseServicing {
    func currentReading() async -> MemoryReading?
    func release() async -> MemoryReleaseResult
}

extension MemoryReleaseService: MemoryReleaseServicing {}

enum TrashState: Equatable {
    case idle
    case scanning
    case clean
    case cleanable(bytes: UInt64, itemCount: Int)
    case cleaning
    case cleaned(bytes: UInt64, itemCount: Int)
    case failed(String)
    case partial(bytes: UInt64, deletedCount: Int, failedCount: Int, remainingBytes: UInt64?)
}

enum MemoryState: Equatable {
    case idle
    case usage(percent: Double)
    case releasing(previousPercent: Double?)
    case released(bytes: UInt64, percentOfTotal: Double)
    case unavailable
    case failed(String)
    case failedToReadMemory
}

enum ProcessActionState: Equatable {
    case idle
    case requested(String)
    case notFound(String)
    case notTerminable(String)
}

@MainActor
final class ActiveCleanupModel: ObservableObject {
    @Published private(set) var trashState: TrashState = .idle
    @Published private(set) var memoryState: MemoryState = .idle
    @Published private(set) var processActionState: ProcessActionState = .idle
    @Published private(set) var apps: [ActiveAppMemoryEntry] = []
    @Published var isTrashConfirmationPresented = false
    @Published private(set) var isCleaningTrash = false
    @Published private(set) var isReleasingMemory = false

    private let trashService: any TrashCleanupServicing
    private let memoryService: any MemoryReleaseServicing
    private let appProvider: any ActiveAppMemoryProviding
    private let limit: Int

    init(
        trashService: any TrashCleanupServicing = TrashCleanupService(),
        memoryService: any MemoryReleaseServicing = MemoryReleaseService(),
        appProvider: any ActiveAppMemoryProviding = ActiveAppMemoryService(),
        limit: Int = 20
    ) {
        self.trashService = trashService
        self.memoryService = memoryService
        self.appProvider = appProvider
        self.limit = limit
    }

    func refresh() async {
        await refreshTrash()
        await refreshMemoryUsage()
        refreshApps()
    }

    func refreshTrash() async {
        trashState = .scanning
        trashState = mapScan(await trashService.scan())
    }

    func refreshMemoryUsage() async {
        guard let reading = await memoryService.currentReading() else {
            memoryState = .unavailable
            return
        }
        memoryState = .usage(percent: reading.pressurePercent)
    }

    func refreshApps() {
        apps = appProvider.topApps(limit: limit)
    }

    func requestTrashCleanupConfirmation() {
        isTrashConfirmationPresented = true
    }

    func confirmTrashCleanup() async {
        guard !isCleaningTrash else { return }
        isTrashConfirmationPresented = false
        isCleaningTrash = true
        defer { isCleaningTrash = false }
        trashState = .cleaning
        let result = await trashService.clean()

        switch result {
        case .cleaned(let bytes, let itemCount):
            switch await trashService.scan() {
            case .clean:
                trashState = .cleaned(bytes: bytes, itemCount: itemCount)
            case .cleanable(let remainingBytes, let remainingCount):
                trashState = .cleanable(bytes: remainingBytes, itemCount: remainingCount)
            case .failed(let message):
                trashState = .failed(message)
            }
        case .partial(let bytes, let deletedCount, let failedCount):
            let remainingBytes = remainingBytesAfterPartialCleanup(await trashService.scan())
            trashState = .partial(bytes: bytes, deletedCount: deletedCount, failedCount: failedCount, remainingBytes: remainingBytes)
        case .failed(let message):
            trashState = .failed(message)
        }
    }

    func releaseMemory() async {
        guard !isReleasingMemory else { return }
        isReleasingMemory = true
        let previousPercent = currentMemoryPercent
        memoryState = .releasing(previousPercent: previousPercent)
        let result = await memoryService.release()
        isReleasingMemory = false

        switch result {
        case .released(let bytes, let percent):
            memoryState = .released(bytes: bytes, percentOfTotal: percent)
        case .unavailable:
            memoryState = .unavailable
        case .failed(let exitCode):
            memoryState = .failed("Memory release failed with exit code \(exitCode).")
        case .failedToReadMemory:
            memoryState = .failedToReadMemory
        }
        refreshApps()
    }

    func quit(_ app: ActiveAppMemoryEntry) {
        switch appProvider.requestTermination(processIdentifier: app.processIdentifier) {
        case .requested:
            processActionState = .requested(app.name)
        case .notFound:
            processActionState = .notFound(app.name)
        case .notTerminable:
            processActionState = .notTerminable(app.name)
        }
        refreshApps()
    }

    private var currentMemoryPercent: Double? {
        if case .usage(let percent) = memoryState { return percent }
        if case .releasing(let previousPercent) = memoryState { return previousPercent }
        return nil
    }

    private func mapScan(_ result: TrashScanResult) -> TrashState {
        switch result {
        case .clean:
            return .clean
        case .cleanable(let bytes, let itemCount):
            return .cleanable(bytes: bytes, itemCount: itemCount)
        case .failed(let message):
            return .failed(message)
        }
    }

    private func remainingBytesAfterPartialCleanup(_ result: TrashScanResult) -> UInt64? {
        switch result {
        case .clean:
            return 0
        case .cleanable(let bytes, _):
            return bytes
        case .failed:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run model tests to verify GREEN**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanupModelTests
```

Expected: all `ActiveCleanupModelTests` pass.

- [ ] **Step 5: Commit model**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git add Sources/MacActivityApp/Models/ActiveCleanupModel.swift Tests/MacActivityAppTests/ActiveCleanupModelTests.swift
cd /Users/how/Git/How/How/MacActivity/mac-activity && git commit -m "feat: add actives cleanup model"
```

Expected: commit succeeds with model and tests.

## Chunk 3: Clean Release SwiftUI

### Task 5: Clean Release SwiftUI Page

**Files:**
- Create: `Sources/MacActivityApp/Views/ActiveCleanReleaseLayout.swift`
- Create: `Sources/MacActivityApp/Views/ActiveCleanReleaseView.swift`
- Create: `Sources/MacActivityApp/Views/TrashCleanupStatusView.swift`
- Create: `Sources/MacActivityApp/Views/MemoryReleaseStatusView.swift`
- Create: `Sources/MacActivityApp/Views/ActiveProcessMemoryList.swift`
- Create: `Sources/MacActivityApp/Views/ActiveProcessMemoryRow.swift`
- Create: `Tests/MacActivityAppTests/ActiveCleanReleaseViewTests.swift`

- [ ] **Step 1: Write view and layout tests**

Create `Tests/MacActivityAppTests/ActiveCleanReleaseViewTests.swift`:

```swift
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class ActiveCleanReleaseViewTests: XCTestCase {
    func testLayoutConstantsMatchCompactCleanReleaseShape() {
        XCTAssertEqual(ActiveCleanReleaseLayout.trashSectionHeight, 103)
        XCTAssertEqual(ActiveCleanReleaseLayout.memoryStripHeight, 44)
        XCTAssertEqual(ActiveCleanReleaseLayout.processRowHeight, ActiveProcessMemoryLayout.rowHeight)
    }

    func testPageCanHostTrashMemoryAndProcessZones() {
        let model = ActiveCleanupModel(
            trashService: ViewTrashCleanupServiceRecorder(scanResults: [.cleanable(bytes: 10, itemCount: 1)]),
            memoryService: ViewMemoryReleaseServiceRecorder(currentReadings: [MemoryReading(usedBytes: 5, totalBytes: 10)]),
            appProvider: ViewActiveAppProviderRecorder(entries: Self.entries(count: 2))
        )
        let hostingView = NSHostingView(rootView: ActiveCleanReleaseView(model: model))

        XCTAssertNotNil(hostingView)
        XCTAssertEqual(ActiveCleanReleaseLayout.zoneOrder, ["trash", "memory", "processes"])
    }

    func testRowHoverSwapsTrailingContentWithoutChangingWidth() {
        XCTAssertEqual(ActiveProcessMemoryRow.trailingContent(isHovered: false), .memory)
        XCTAssertEqual(ActiveProcessMemoryRow.trailingContent(isHovered: true), .quit)
        XCTAssertEqual(ActiveProcessMemoryLayout.trailingActionWidth, 72)
    }

    func testSectionLocalErrorTextComesFromProducingSection() {
        XCTAssertEqual(TrashCleanupStatusView.title(for: .failed("denied")), "Trash Cleanup Failed")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .failed("denied")), "denied")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .failed("boom")), "Memory Release Failed")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .failed("boom")), "boom")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .unavailable), "Memory Release Unavailable")
    }

    func testMemoryReleasingStateShowsProgressIndicator() {
        XCTAssertTrue(MemoryReleaseStatusView.showsProgressIndicator(for: .releasing(previousPercent: 44)))
        XCTAssertFalse(MemoryReleaseStatusView.showsProgressIndicator(for: .usage(percent: 44)))
    }

    static func entries(count: Int) -> [ActiveAppMemoryEntry] {
        (0..<count).map { index in
            ActiveAppMemoryEntry(
                processIdentifier: pid_t(2_000 + index),
                name: "View App \(index)",
                bundleIdentifier: "com.example.view\(index)",
                residentMemoryBytes: UInt64((count - index) * 1_000),
                isTerminable: true
            )
        }
    }
}

@MainActor
private final class ViewTrashCleanupServiceRecorder: TrashCleanupServicing {
    var scanResults: [TrashScanResult]
    var cleanResults: [TrashCleanupResult]

    init(scanResults: [TrashScanResult] = [.clean], cleanResults: [TrashCleanupResult] = [.cleaned(bytes: 0, itemCount: 0)]) {
        self.scanResults = scanResults
        self.cleanResults = cleanResults
    }

    func scan() async -> TrashScanResult {
        guard scanResults.isEmpty == false else { return .clean }
        return scanResults.removeFirst()
    }

    func clean() async -> TrashCleanupResult {
        guard cleanResults.isEmpty == false else { return .cleaned(bytes: 0, itemCount: 0) }
        return cleanResults.removeFirst()
    }
}

@MainActor
private final class ViewMemoryReleaseServiceRecorder: MemoryReleaseServicing {
    var currentReadings: [MemoryReading]

    init(currentReadings: [MemoryReading] = []) {
        self.currentReadings = currentReadings
    }

    func currentReading() async -> MemoryReading? {
        guard currentReadings.isEmpty == false else { return nil }
        return currentReadings.removeFirst()
    }

    func release() async -> MemoryReleaseResult {
        .unavailable
    }
}

@MainActor
private final class ViewActiveAppProviderRecorder: ActiveAppMemoryProviding {
    var entries: [ActiveAppMemoryEntry]

    init(entries: [ActiveAppMemoryEntry] = []) {
        self.entries = entries
    }

    func topApps(limit: Int) -> [ActiveAppMemoryEntry] {
        Array(entries.prefix(limit))
    }

    func requestTermination(processIdentifier: pid_t) -> ActiveAppTerminationResult {
        .notFound
    }
}
```

- [ ] **Step 2: Run view tests to verify RED**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanReleaseViewTests
```

Expected: compile failure because the clean-release views and `ActiveCleanReleaseLayout` do not exist.

- [ ] **Step 3: Implement layout constants**

Create `Sources/MacActivityApp/Views/ActiveCleanReleaseLayout.swift`:

```swift
import Foundation

enum ActiveCleanReleaseLayout {
    static let trashSectionHeight: CGFloat = 103
    static let memoryStripHeight: CGFloat = 44
    static let processRowHeight: CGFloat = ActiveProcessMemoryLayout.rowHeight
    static let processListSpacing: CGFloat = 0
    static let sectionSpacing: CGFloat = 10
    static let zoneOrder = ["trash", "memory", "processes"]
}
```

- [ ] **Step 4: Implement root clean-release view**

Create `Sources/MacActivityApp/Views/ActiveCleanReleaseView.swift`:

```swift
import SwiftUI

struct ActiveCleanReleaseView: View {
    @ObservedObject var model: ActiveCleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.sectionSpacing) {
            TrashCleanupStatusView(model: model)
                .accessibilityIdentifier("actives-clean-release-trash")

            MemoryReleaseStatusView(model: model)
                .accessibilityIdentifier("actives-clean-release-memory")

            ActiveProcessMemoryList(model: model)
                .accessibilityIdentifier("actives-clean-release-processes")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $model.isTrashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                Task { await model.confirmTrashCleanup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the current user's Trash contents.")
        }
        .task {
            await model.refresh()
        }
    }
}
```

- [ ] **Step 5: Implement Trash section**

Create `Sources/MacActivityApp/Views/TrashCleanupStatusView.swift`:

```swift
import SwiftUI

struct TrashCleanupStatusView: View {
    @ObservedObject var model: ActiveCleanupModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(DashboardCardLayout.regularCardInsets)
        .frame(maxWidth: .infinity, minHeight: ActiveCleanReleaseLayout.trashSectionHeight, alignment: .center)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var action: some View {
        switch model.trashState {
        case .scanning, .cleaning:
            ProgressView().controlSize(.small)
        case .failed:
            Button("Retry") { Task { await model.refreshTrash() } }
        case .cleanable:
            Button("Clean") { model.requestTrashCleanupConfirmation() }
                .disabled(model.isCleaningTrash)
        default:
            EmptyView()
        }
    }

    private var title: String {
        Self.title(for: model.trashState)
    }

    static func title(for state: TrashState) -> String {
        switch state {
        case .idle, .scanning: return "Scanning Trash"
        case .clean: return "Trash Is Clean"
        case .cleanable(let bytes, _): return "\(format(bytes)) in Trash"
        case .cleaning: return "Cleaning Trash"
        case .cleaned(let bytes, _): return "Cleaned \(format(bytes))"
        case .partial(let bytes, _, _, _): return "Cleaned \(format(bytes))"
        case .failed: return "Trash Cleanup Failed"
        }
    }

    private var subtitle: String {
        Self.subtitle(for: model.trashState)
    }

    static func subtitle(for state: TrashState) -> String {
        switch state {
        case .idle, .scanning: return "Checking the current user's Trash."
        case .clean: return "No cleanable Trash items found."
        case .cleanable(_, let itemCount): return "\(itemCount) item(s) can be removed after confirmation."
        case .cleaning: return "Deleting confirmed Trash contents."
        case .cleaned(_, let itemCount): return "Removed \(itemCount) item(s)."
        case .partial(_, let deletedCount, let failedCount, let remainingBytes):
            let remaining = remainingBytes.map { " \(format($0)) remains." } ?? ""
            return "Removed \(deletedCount) item(s); \(failedCount) item(s) could not be deleted." + remaining
        case .failed(let message): return message
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
```

- [ ] **Step 6: Implement Memory section**

Create `Sources/MacActivityApp/Views/MemoryReleaseStatusView.swift`:

```swift
import SwiftUI

struct MemoryReleaseStatusView: View {
    @ObservedObject var model: ActiveCleanupModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if Self.showsProgressIndicator(for: model.memoryState) {
                ProgressView().controlSize(.small)
            }
            Button(model.isReleasingMemory ? "Releasing" : "Release") {
                Task { await model.releaseMemory() }
            }
            .disabled(model.isReleasingMemory)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: ActiveCleanReleaseLayout.memoryStripHeight, alignment: .center)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var title: String {
        Self.title(for: model.memoryState)
    }

    static func title(for state: MemoryState) -> String {
        switch state {
        case .usage(let percent): return "Memory \(percent.rounded())%"
        case .releasing: return "Releasing Memory"
        case .released(let bytes, _): return "Released \(format(bytes))"
        case .unavailable: return "Memory Release Unavailable"
        case .failed: return "Memory Release Failed"
        case .failedToReadMemory: return "Memory Reading Failed"
        case .idle: return "Memory"
        }
    }

    private var subtitle: String {
        Self.subtitle(for: model.memoryState)
    }

    static func subtitle(for state: MemoryState) -> String {
        switch state {
        case .released(_, let percent): return String(format: "%.1f%% of total memory", percent)
        case .failed(let message): return message
        case .failedToReadMemory: return "Unable to compare before and after memory readings."
        case .unavailable: return "The clean command is unavailable on this Mac."
        default: return "Release reclaimable system memory."
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    static func showsProgressIndicator(for state: MemoryState) -> Bool {
        if case .releasing = state { return true }
        return false
    }
}
```

- [ ] **Step 7: Implement process list and rows**

Create `Sources/MacActivityApp/Views/ActiveProcessMemoryList.swift`:

```swift
import SwiftUI

struct ActiveProcessMemoryList: View {
    @ObservedObject var model: ActiveCleanupModel

    var body: some View {
        VStack(spacing: ActiveCleanReleaseLayout.processListSpacing) {
            if model.apps.isEmpty {
                Text("No foreground apps are reporting memory usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: ActiveProcessMemoryLayout.rowHeight, alignment: .leading)
            } else {
                ForEach(model.apps) { app in
                    ActiveProcessMemoryRow(
                        app: app,
                        maxBytes: model.apps.map(\.residentMemoryBytes).max() ?? 0
                    ) {
                        model.quit(app)
                    }
                    if app.id != model.apps.last?.id {
                        Divider().padding(.leading, 28)
                    }
                }
            }
            actionMessage
        }
    }

    @ViewBuilder
    private var actionMessage: some View {
        switch model.processActionState {
        case .idle:
            EmptyView()
        case .requested(let name):
            Text("Requested \(name) to quit.")
        case .notFound(let name):
            Text("\(name) is no longer running.")
        case .notTerminable(let name):
            Text("\(name) could not be quit safely.")
        }
    }
}
```

Create `Sources/MacActivityApp/Views/ActiveProcessMemoryRow.swift`:

```swift
import SwiftUI
import MacActivityCore

enum ActiveProcessMemoryRowTrailingContent: Equatable {
    case memory
    case quit
}

struct ActiveProcessMemoryRow: View {
    let app: ActiveAppMemoryEntry
    let maxBytes: UInt64
    let quit: () -> Void
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: proxy.size.width * ActiveProcessMemoryLayout.progress(bytes: app.residentMemoryBytes, maxBytes: maxBytes))
                rowContent
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: ActiveProcessMemoryLayout.rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.caption.weight(.medium)).lineLimit(1)
                if let bundleIdentifier = app.bundleIdentifier {
                    Text(bundleIdentifier).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
                .frame(width: ActiveProcessMemoryLayout.trailingActionWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch Self.trailingContent(isHovered: isHovered) {
        case .quit:
            Button("Quit", action: quit)
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!app.isTerminable)
        case .memory:
            Text(app.formattedResidentMemory)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
    }

    static func trailingContent(isHovered: Bool) -> ActiveProcessMemoryRowTrailingContent {
        isHovered ? .quit : .memory
    }
}
```

- [ ] **Step 8: Run view tests to verify GREEN**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanReleaseViewTests
```

Expected: all `ActiveCleanReleaseViewTests` pass.

- [ ] **Step 9: Commit SwiftUI page**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git add Sources/MacActivityApp/Views/ActiveCleanReleaseLayout.swift Sources/MacActivityApp/Views/ActiveCleanReleaseView.swift Sources/MacActivityApp/Views/TrashCleanupStatusView.swift Sources/MacActivityApp/Views/MemoryReleaseStatusView.swift Sources/MacActivityApp/Views/ActiveProcessMemoryList.swift Sources/MacActivityApp/Views/ActiveProcessMemoryRow.swift Tests/MacActivityAppTests/ActiveCleanReleaseViewTests.swift
cd /Users/how/Git/How/How/MacActivity/mac-activity && git commit -m "feat: add actives clean release view"
```

Expected: commit succeeds with the six view files and the view test file.

### Task 6: Wire Dashboard Actives Tab

**Files:**
- Modify: `Sources/MacActivityApp/Views/DashboardView.swift`

- [ ] **Step 1: Replace the old Actives owner**

Modify `Sources/MacActivityApp/Views/DashboardView.swift`:

```swift
@StateObject private var activeCleanupModel = ActiveCleanupModel()
```

Replace the current `activesContent` implementation with:

```swift
private var activesContent: some View {
    ActiveCleanReleaseView(model: activeCleanupModel)
        .padding(18)
}
```

Remove the private `ActiveAppsModel`, `ActiveAppsMemoryCard`, and `ActiveAppRow` declarations from `DashboardView.swift`. Remove the old `.onAppear` and `.onChange` calls that refresh `activeAppsModel`; `ActiveCleanReleaseView.task` owns its own refresh.

- [ ] **Step 2: Build to catch wiring errors**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift build
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanupModelTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanReleaseViewTests
```

Expected: build passes and both test filters pass.

- [ ] **Step 3: Commit dashboard wiring**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git add Sources/MacActivityApp/Views/DashboardView.swift
cd /Users/how/Git/How/How/MacActivity/mac-activity && git commit -m "feat: wire actives clean release page"
```

Expected: commit succeeds with only `DashboardView.swift`.

## Chunk 4: Project Sync and Verification

### Task 7: Regenerate Xcode Project

**Files:**
- Modify: `MacActivity.xcodeproj/project.pbxproj`
- Inspect: `MacActivity.xcodeproj/xcshareddata/xcschemes/MacActivity.xcscheme`
- Inspect: `MacActivity.xcodeproj/project.xcworkspace/contents.xcworkspacedata`

- [ ] **Step 1: Regenerate project files**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && xcodegen generate
```

Expected: XcodeGen exits successfully and includes the new source and test files in the generated project.

- [ ] **Step 2: Inspect generated project changes**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git diff -- MacActivity.xcodeproj/project.pbxproj MacActivity.xcodeproj/xcshareddata/xcschemes/MacActivity.xcscheme MacActivity.xcodeproj/project.xcworkspace/contents.xcworkspacedata
cd /Users/how/Git/How/How/MacActivity/mac-activity && git status --short MacActivity.xcodeproj
```

Expected: `project.pbxproj` has file-reference and build-phase changes for the new Core, App, and test files. The scheme and workspace files should have no diff; if either changes, inspect and explain before committing.

- [ ] **Step 3: Commit project sync**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git add MacActivity.xcodeproj/project.pbxproj
cd /Users/how/Git/How/How/MacActivity/mac-activity && git commit -m "chore: sync xcode project for actives cleanup"
```

Expected: commit succeeds with only `project.pbxproj`, unless Step 2 produced an explained intentional project metadata change.

### Task 8: Focused and Full Verification

**Files:**
- Verify only; no planned source edits.

- [ ] **Step 1: Run focused Core tests**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter TrashCleanupServiceTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter MemoryReleaseServiceTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveAppMemoryProvidingTests
```

Expected: all focused Core tests pass.

- [ ] **Step 2: Run focused App tests**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanupModelTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveProcessMemoryLayoutTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter ActiveCleanReleaseViewTests
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests
```

Expected: all focused App tests pass.

- [ ] **Step 3: Run full SwiftPM verification**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test
```

Expected: full SwiftPM test suite passes.

- [ ] **Step 4: Run Xcode verification with a fresh result bundle**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && rm -rf /private/tmp/MacActivityActivesCleanup.xcresult
cd /Users/how/Git/How/How/MacActivity/mac-activity && xcodebuild test -scheme MacActivity -configuration Debug -derivedDataPath /private/tmp/MacActivityDerivedData -resultBundlePath /private/tmp/MacActivityActivesCleanup.xcresult
```

Expected: Xcode test action passes and writes `/private/tmp/MacActivityActivesCleanup.xcresult`.

- [ ] **Step 5: Runtime smoke check the Actives page**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift run MacActivityApp
```

Expected manual checks:
- Open the dashboard popover and select `Actives`.
- Confirm the page order is Trash, Memory, then process list.
- Confirm Trash shows size, clean, scanning, or a section-local error.
- Click Trash `Clean`, then choose `Cancel`; do not confirm deletion of the real Trash during this smoke check.
- Confirm the Memory strip shows the current usage percent and a `Release` action.
- Click `Release` and confirm the strip changes to released, unavailable, or failed with visible text.
- Confirm process rows show horizontal bars scaled by visible resident memory.
- Hover a process row and confirm the right side swaps from memory size to `Quit` without changing row height.
- Confirm `Quit` remains a polite request and no force-kill UI appears.

- [ ] **Step 6: Final clean diff checks**

Run:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity && git diff --check
cd /Users/how/Git/How/How/MacActivity/mac-activity && git status --short
```

Expected: `git diff --check` prints no errors. `git status --short` is clean after the commits above. If it is not clean, return to the failing task, fix the issue, rerun the relevant verification commands, and commit the exact changed files for that task.
