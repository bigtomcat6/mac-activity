import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class ActiveCleanReleaseViewTests: XCTestCase {
    func testLayoutConstantsMatchCompactCleanReleaseShape() {
        XCTAssertEqual(ActiveCleanReleaseLayout.memoryStripHeight, 44)
        XCTAssertEqual(ActiveCleanReleaseLayout.processRowHeight, ActiveProcessMemoryLayout.rowHeight)
    }

    func testPageCanHostMemoryAndProcessZones() {
        let model = ActiveCleanupModel(
            trashService: ViewTrashCleanupServiceRecorder(scanResults: [.clean]),
            memoryService: ViewMemoryReleaseServiceRecorder(
                currentReadings: [MemoryReading(usedBytes: 4, totalBytes: 10)]
            ),
            appProvider: ViewActiveAppProviderRecorder(entries: Self.entries(count: 2))
        )

        let hostingView = NSHostingView(rootView: ActiveCleanReleaseView(model: model))

        XCTAssertNotNil(hostingView)
        XCTAssertEqual(ActiveCleanReleaseLayout.zoneOrder, ["memory", "processes"])
    }

    func testRowHoverSwapsTrailingContentWithoutChangingWidth() {
        XCTAssertEqual(
            ActiveProcessMemoryRow.trailingContent(isHovered: false, quitConfirmationState: .inactive),
            .memory
        )
        XCTAssertEqual(
            ActiveProcessMemoryRow.trailingContent(isHovered: true, quitConfirmationState: .inactive),
            .quit
        )
        XCTAssertEqual(
            ActiveProcessMemoryRow.trailingContent(isHovered: false, quitConfirmationState: .confirming),
            .confirmQuit
        )
        XCTAssertEqual(ActiveProcessMemoryLayout.trailingActionWidth, 72)
    }

    func testQuitButtonRequiresSecondClickToRequestTermination() {
        let firstClick = ActiveProcessQuitConfirmationReducer.reduce(.inactive, event: .quitButtonClicked)

        XCTAssertEqual(firstClick.state, .confirming)
        XCTAssertFalse(firstClick.shouldQuit)

        let secondClick = ActiveProcessQuitConfirmationReducer.reduce(.confirming, event: .quitButtonClicked)

        XCTAssertEqual(secondClick.state, .inactive)
        XCTAssertTrue(secondClick.shouldQuit)
    }

    func testQuitConfirmationCancelsFromOutsideClickOrTimeout() {
        let outsideClick = ActiveProcessQuitConfirmationReducer.reduce(.confirming, event: .outsideClicked)
        let timeout = ActiveProcessQuitConfirmationReducer.reduce(.confirming, event: .timedOut)

        XCTAssertEqual(outsideClick.state, .inactive)
        XCTAssertFalse(outsideClick.shouldQuit)
        XCTAssertEqual(timeout.state, .inactive)
        XCTAssertFalse(timeout.shouldQuit)
    }

    func testQuitButtonConfigurationTurnsDestructiveWhileConfirming() {
        XCTAssertEqual(
            ActiveProcessMemoryRow.quitButtonConfiguration(for: .inactive),
            ActiveProcessQuitButtonConfiguration(title: "Quit", isDestructive: false)
        )
        XCTAssertEqual(
            ActiveProcessMemoryRow.quitButtonConfiguration(for: .confirming),
            ActiveProcessQuitButtonConfiguration(title: "Confirm", isDestructive: true)
        )
    }

    func testProcessRowUsesBundleURLWhenChoosingIconSource() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let appWithBundle = ActiveAppMemoryEntry(
            processIdentifier: 2_101,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: bundleURL,
            residentMemoryBytes: 1_024,
            isTerminable: true
        )
        let appWithoutBundle = ActiveAppMemoryEntry(
            processIdentifier: 2_102,
            name: "Helper",
            bundleIdentifier: nil,
            bundleURL: nil,
            residentMemoryBytes: 512,
            isTerminable: true
        )

        XCTAssertEqual(ActiveProcessMemoryRow.iconSource(for: appWithBundle), .bundle(bundleURL))
        XCTAssertEqual(ActiveProcessMemoryRow.iconSource(for: appWithoutBundle), .fallbackSystemSymbol)
    }

    func testProcessRowFallsBackWhenBundleURLDoesNotExist() {
        let missingBundle = URL(fileURLWithPath: "/Applications/Missing.app")
        let app = ActiveAppMemoryEntry(
            processIdentifier: 2_103,
            name: "Missing",
            bundleIdentifier: "com.example.missing",
            bundleURL: missingBundle,
            residentMemoryBytes: 1_024,
            isTerminable: true
        )

        XCTAssertEqual(
            ActiveProcessMemoryRow.iconSource(for: app, fileExists: { _ in false }),
            .fallbackSystemSymbol
        )
    }

    func testSectionLocalErrorTextComesFromProducingSection() {
        XCTAssertEqual(TrashCleanupStatusView.title(for: .failed("denied")), "Trash Cleanup Failed")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .failed("denied")), "denied")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .failed("boom")), "Memory Release Failed")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .failed("boom")), "boom")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .unavailable), "Memory Release Not Available")
    }

    func testMemoryReleasingStateShowsProgressIndicator() {
        XCTAssertTrue(MemoryReleaseStatusView.showsProgressIndicator(for: .releasing(previousPercent: 44)))
        XCTAssertFalse(MemoryReleaseStatusView.showsProgressIndicator(for: .usage(percent: 44)))
    }

    func testTrashHelperTextMatchesCleanReleasePlan() {
        let cleanableBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 4_096)
        let cleanedBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 8_192)
        let partialBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 12_288)
        let remainingBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 2_048)

        XCTAssertEqual(TrashCleanupStatusView.title(for: .idle), "Scanning Trash")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .idle), "Checking the current user's Trash.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .scanning), "Scanning Trash")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .scanning), "Checking the current user's Trash.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .clean), "Trash Is Clean")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .clean), "No cleanable Trash items found.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .cleanable(bytes: 4_096, itemCount: 2)), "\(cleanableBytes) in Trash")
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(for: .cleanable(bytes: 4_096, itemCount: 2)),
            "2 items can be removed after confirmation."
        )
        XCTAssertEqual(TrashCleanupStatusView.title(for: .cleaning), "Cleaning Trash")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .cleaning), "Deleting confirmed Trash contents.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .cleaned(bytes: 8_192, itemCount: 1)), "Cleaned \(cleanedBytes)")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .cleaned(bytes: 8_192, itemCount: 1)), "Removed 1 item.")
        XCTAssertEqual(
            TrashCleanupStatusView.title(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048)
            ),
            "Cleaned \(partialBytes)"
        )
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048)
            ),
            "Removed 3 items; 1 item could not be deleted. \(remainingBytes) remains."
        )
        XCTAssertEqual(TrashCleanupStatusView.title(for: .failed("denied")), "Trash Cleanup Failed")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .failed("denied")), "denied")
    }

    func testMemoryHelperTextMatchesCleanReleasePlan() {
        let releasedBytes = MemoryReleaseStatusView.byteFormatter.string(fromByteCount: 65_536)

        XCTAssertEqual(MemoryReleaseStatusView.title(for: .idle), "Memory")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .idle), "Release reclaimable system memory.")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .usage(percent: 44.4)), "Memory 44%")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .usage(percent: 44.4)), "Release reclaimable system memory.")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .releasing(previousPercent: 44)), "Releasing Memory")
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(for: .releasing(previousPercent: 44)),
            "Release reclaimable system memory."
        )
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .released(bytes: 65_536, percentOfTotal: 2.5)), "Released \(releasedBytes)")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .released(bytes: 65_536, percentOfTotal: 2.5)), "2.5% of total memory")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .unavailable), "Memory Release Not Available")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .unavailable), "No supported memory release method is available on this Mac.")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .failed("boom")), "Memory Release Failed")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .failed("boom")), "boom")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .failedToReadMemory), "Memory Reading Failed")
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(for: .failedToReadMemory),
            "Unable to compare before and after memory readings."
        )
    }

    func testProcessActionMessagesMatchCleanReleasePlan() {
        XCTAssertNil(ActiveProcessMemoryList.processActionMessage(for: .idle))
        XCTAssertEqual(
            ActiveProcessMemoryList.processActionMessage(for: .requested("Safari")),
            "Requested Safari to quit."
        )
        XCTAssertEqual(
            ActiveProcessMemoryList.processActionMessage(for: .notFound("Mail")),
            "Mail is no longer running."
        )
        XCTAssertEqual(
            ActiveProcessMemoryList.processActionMessage(for: .notTerminable("Finder")),
            "Finder could not be quit safely."
        )
    }

    static func entries(count: Int) -> [ActiveAppMemoryEntry] {
        (0..<count).map { index in
            ActiveAppMemoryEntry(
                processIdentifier: pid_t(2_000 + index),
                name: "View App \(index)",
                bundleIdentifier: "com.example.view-app-\(index)",
                bundleURL: URL(fileURLWithPath: "/Applications/View App \(index).app"),
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

    init(
        scanResults: [TrashScanResult] = [],
        cleanResults: [TrashCleanupResult] = [.cleaned(bytes: 0, itemCount: 0)]
    ) {
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
    var releaseResults: [MemoryReleaseResult]

    init(
        currentReadings: [MemoryReading] = [],
        releaseResults: [MemoryReleaseResult] = [.unavailable]
    ) {
        self.currentReadings = currentReadings
        self.releaseResults = releaseResults
    }

    func currentReading() async -> MemoryReading? {
        guard currentReadings.isEmpty == false else { return nil }
        return currentReadings.removeFirst()
    }

    func release() async -> MemoryReleaseResult {
        guard releaseResults.isEmpty == false else { return .unavailable }
        return releaseResults.removeFirst()
    }
}

@MainActor
private final class ViewActiveAppProviderRecorder: ActiveAppMemoryProviding {
    var entries: [ActiveAppMemoryEntry]
    var terminationResults: [ActiveAppTerminationResult]

    init(
        entries: [ActiveAppMemoryEntry] = [],
        terminationResults: [ActiveAppTerminationResult] = []
    ) {
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
