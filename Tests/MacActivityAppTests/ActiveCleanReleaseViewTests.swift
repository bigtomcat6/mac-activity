import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class ActiveCleanReleaseViewTests: XCTestCase {
    private static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
    }

    func testLayoutConstantsMatchCompactCleanReleaseShape() {
        XCTAssertEqual(ActiveCleanReleaseLayout.diskCleanupStripHeight, 44)
        XCTAssertEqual(ActiveCleanReleaseLayout.processRowHeight, ActiveProcessMemoryLayout.rowHeight)
    }

    func testPageCanHostDiskCleanupAndProcessZones() {
        let model = ActiveCleanupModel(
            trashService: ViewTrashCleanupServiceRecorder(scanResults: [.clean]),
            memoryService: ViewMemoryReleaseServiceRecorder(
                currentReadings: [MemoryReading(usedBytes: 4, totalBytes: 10)]
            ),
            diskCleanupService: ViewDiskCleanupServiceRecorder(scanResults: [.clean]),
            appProvider: ViewActiveAppProviderRecorder(entries: Self.entries(count: 2))
        )

        let hostingView = NSHostingView(rootView: ActiveCleanReleaseView(model: model))

        XCTAssertNotNil(hostingView)
        XCTAssertEqual(ActiveCleanReleaseLayout.zoneOrder, ["diskCleanup", "processes"])
    }

    func testRenderedProcessListRestoresTransparentGapBetweenRows() async throws {
        let model = ActiveCleanupModel(
            trashService: ViewTrashCleanupServiceRecorder(scanResults: [.clean]),
            memoryService: ViewMemoryReleaseServiceRecorder(
                currentReadings: [MemoryReading(usedBytes: 4, totalBytes: 10)]
            ),
            diskCleanupService: ViewDiskCleanupServiceRecorder(scanResults: [.clean]),
            appProvider: ViewActiveAppProviderRecorder(
                entries: [
                    ActiveAppMemoryEntry(
                        processIdentifier: 2_201,
                        name: "First",
                        bundleIdentifier: "com.example.first",
                        bundleURL: URL(fileURLWithPath: "/Applications/First.app"),
                        residentMemoryBytes: 250,
                        isTerminable: true
                    ),
                    ActiveAppMemoryEntry(
                        processIdentifier: 2_202,
                        name: "Second",
                        bundleIdentifier: "com.example.second",
                        bundleURL: URL(fileURLWithPath: "/Applications/Second.app"),
                        residentMemoryBytes: 1_000,
                        isTerminable: true
                    ),
                ]
            )
        )
        await model.refreshVisibleCleanReleaseSections()

        let content = ActiveProcessMemoryList(model: model)
            .frame(width: 360, height: 90, alignment: .topLeading)
        let processGapY = ActiveProcessMemoryLayout.rowHeight + (ActiveCleanReleaseLayout.processListSpacing / 2)
        let processGapColor = try XCTUnwrap(
            Self.renderedColor(of: content, atTopLeft: CGPoint(x: 210, y: processGapY))
        )

        XCTAssertLessThan(
            processGapColor.alphaComponent,
            0.02,
            "Expected the process-list gap to restore the original transparent divider spacing. gap=\(Self.debugColor(processGapColor))"
        )
    }

    func testRenderedProcessProgressUsesNeutralToneWhenWindowIsInactive() throws {
        let app = ActiveAppMemoryEntry(
            processIdentifier: 2_210,
            name: "A",
            bundleIdentifier: "b",
            bundleURL: nil,
            residentMemoryBytes: 1_000,
            isTerminable: true
        )

        let activeRow = ActiveProcessMemoryRow(app: app, maxBytes: 1_000, quit: {})
            .frame(width: 360, height: ActiveProcessMemoryLayout.rowHeight)
            .environment(\.appearsActive, true)
        let inactiveRow = ActiveProcessMemoryRow(app: app, maxBytes: 1_000, quit: {})
            .frame(width: 360, height: ActiveProcessMemoryLayout.rowHeight)
            .environment(\.appearsActive, false)

        let activeReference = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(ActiveCleanupChrome.progressFillColor(appearsActive: true))
                    .frame(width: 32, height: 32),
                atTopLeft: CGPoint(x: 16, y: 16)
            )
        )
        let inactiveReference = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(ActiveCleanupChrome.progressFillColor(appearsActive: false))
                    .frame(width: 32, height: 32),
                atTopLeft: CGPoint(x: 16, y: 16)
            )
        )
        let activeColor = try XCTUnwrap(Self.renderedColor(of: activeRow, atTopLeft: CGPoint(x: 200, y: 19)))
        let inactiveColor = try XCTUnwrap(Self.renderedColor(of: inactiveRow, atTopLeft: CGPoint(x: 200, y: 19)))

        XCTAssertTrue(
            Self.colorsApproximatelyEqual(activeColor, activeReference, tolerance: 0.08),
            "Expected active process fill to keep the accent tone. reference=\(Self.debugColor(activeReference)) actual=\(Self.debugColor(activeColor))"
        )
        XCTAssertTrue(
            Self.colorsApproximatelyEqual(inactiveColor, inactiveReference, tolerance: 0.08),
            "Expected inactive process fill to switch to the neutral dark tone. reference=\(Self.debugColor(inactiveReference)) actual=\(Self.debugColor(inactiveColor))"
        )
    }

    func testRenderedProcessRowRestoresTransparentSpaceOutsideProgressFill() throws {
        let app = ActiveAppMemoryEntry(
            processIdentifier: 2_333,
            name: "Chrome Test",
            bundleIdentifier: "com.example.chrome-test",
            bundleURL: nil,
            residentMemoryBytes: 200,
            isTerminable: true
        )

        let row = ActiveProcessMemoryRow(app: app, maxBytes: 1_000, quit: {})
            .frame(width: 360, height: ActiveProcessMemoryLayout.rowHeight)
            .environment(\.appearsActive, true)

        let actual = try XCTUnwrap(
            Self.renderedColor(of: row, atTopLeft: CGPoint(x: 300, y: 19))
        )

        XCTAssertLessThan(
            actual.alphaComponent,
            0.02,
            "Expected the original row shape to leave the area outside progress fill transparent. actual=\(Self.debugColor(actual))"
        )
    }

    func testRenderedProcessRowLeavesInteriorBottomCornersSquare() throws {
        let app = ActiveAppMemoryEntry(
            processIdentifier: 2_334,
            name: "Corner Test",
            bundleIdentifier: "com.example.corner-test",
            bundleURL: nil,
            residentMemoryBytes: 1_000,
            isTerminable: true
        )

        let row = ActiveProcessMemoryRow(app: app, maxBytes: 1_000, quit: {})
            .frame(width: 360, height: ActiveProcessMemoryLayout.rowHeight)
            .environment(\.appearsActive, true)

        let reference = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(ActiveCleanupChrome.progressFillColor(appearsActive: true))
                    .frame(width: 32, height: 32),
                atTopLeft: CGPoint(x: 16, y: 16)
            )
        )
        let actual = try XCTUnwrap(
            Self.renderedColor(
                of: row,
                atTopLeft: CGPoint(x: 1, y: ActiveProcessMemoryLayout.rowHeight - 1)
            )
        )

        XCTAssertTrue(
            Self.colorsApproximatelyEqual(actual, reference, tolerance: 0.08),
            "Expected process rows to keep interior corners square; only the outer list edge should round. reference=\(Self.debugColor(reference)) actual=\(Self.debugColor(actual))"
        )
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

    func testRowShowsRefreshAnimationWhileQuitIsPending() {
        XCTAssertEqual(
            ActiveProcessMemoryRow.trailingContent(
                isHovered: false,
                quitConfirmationState: .inactive,
                isQuitPending: true
            ),
            .quitting
        )
        XCTAssertEqual(
            ActiveProcessMemoryRow.trailingContent(
                isHovered: true,
                quitConfirmationState: .confirming,
                isQuitPending: true
            ),
            .quitting
        )
    }

    func testPendingQuitRefreshAnimationUsesTrailingAlignment() {
        XCTAssertEqual(
            ActiveProcessMemoryRow.trailingContentAlignment(for: .quitting),
            .trailing
        )
    }

    func testQuitButtonRequiresSecondClickToRequestTermination() {
        let firstClick = ActiveProcessQuitConfirmationReducer.reduce(.inactive, event: .quitButtonClicked)

        XCTAssertEqual(firstClick.state, .confirming)
        XCTAssertFalse(firstClick.shouldQuit)

        let secondClick = ActiveProcessQuitConfirmationReducer.reduce(.confirming, event: .quitButtonClicked)

        XCTAssertEqual(secondClick.state, .inactive)
        XCTAssertTrue(secondClick.shouldQuit)
    }

    func testDiskCleanupButtonRequiresSecondClickToClean() {
        let firstClick = DiskCleanupConfirmationReducer.reduce(.inactive, event: .cleanButtonClicked)

        XCTAssertEqual(firstClick.state, .confirming)
        XCTAssertFalse(firstClick.shouldClean)

        let secondClick = DiskCleanupConfirmationReducer.reduce(.confirming, event: .cleanButtonClicked)

        XCTAssertEqual(secondClick.state, .inactive)
        XCTAssertTrue(secondClick.shouldClean)
    }

    func testQuitConfirmationCancelsFromOutsideClickOrTimeout() {
        let outsideClick = ActiveProcessQuitConfirmationReducer.reduce(.confirming, event: .outsideClicked)
        let timeout = ActiveProcessQuitConfirmationReducer.reduce(.confirming, event: .timedOut)

        XCTAssertEqual(outsideClick.state, .inactive)
        XCTAssertFalse(outsideClick.shouldQuit)
        XCTAssertEqual(timeout.state, .inactive)
        XCTAssertFalse(timeout.shouldQuit)
    }

    func testDiskCleanupConfirmationCancelsFromOutsideClickOrTimeout() {
        let outsideClick = DiskCleanupConfirmationReducer.reduce(.confirming, event: .outsideClicked)
        let timeout = DiskCleanupConfirmationReducer.reduce(.confirming, event: .timedOut)

        XCTAssertEqual(outsideClick.state, .inactive)
        XCTAssertFalse(outsideClick.shouldClean)
        XCTAssertEqual(timeout.state, .inactive)
        XCTAssertFalse(timeout.shouldClean)
    }

    func testQuitButtonConfigurationTurnsDestructiveWhileConfirming() {
        XCTAssertEqual(
            ActiveProcessMemoryRow.quitButtonConfiguration(for: .inactive, bundle: Self.englishBundle),
            ActiveProcessQuitButtonConfiguration(title: "Quit", isDestructive: false)
        )
        XCTAssertEqual(
            ActiveProcessMemoryRow.quitButtonConfiguration(for: .confirming, bundle: Self.englishBundle),
            ActiveProcessQuitButtonConfiguration(title: "Confirm", isDestructive: true)
        )
    }

    func testConfirmButtonOnlyUsesProminentEmphasisWhileWindowIsActive() {
        XCTAssertEqual(
            ActiveProcessQuitButtonStyling.visualStyle(for: .inactive, appearsActive: true),
            .bordered
        )
        XCTAssertEqual(
            ActiveProcessQuitButtonStyling.visualStyle(for: .confirming, appearsActive: true),
            .destructiveProminent
        )
        XCTAssertEqual(
            ActiveProcessQuitButtonStyling.visualStyle(for: .confirming, appearsActive: false),
            .bordered
        )
    }

    func testDiskCleanupButtonConfigurationTurnsDestructiveWhileConfirming() {
        XCTAssertEqual(
            DiskCleanupStatusView.buttonConfiguration(for: .inactive, bundle: Self.englishBundle),
            DiskCleanupActionButtonConfiguration(title: "Clean", isDestructive: false)
        )
        XCTAssertEqual(
            DiskCleanupStatusView.buttonConfiguration(for: .confirming, bundle: Self.englishBundle),
            DiskCleanupActionButtonConfiguration(title: "Confirm", isDestructive: true)
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
        let english = Self.englishBundle

        XCTAssertEqual(TrashCleanupStatusView.title(for: .failed("denied"), bundle: english), "Trash Cleanup Failed")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .failed("denied"), bundle: english), "denied")
        XCTAssertEqual(DiskCleanupStatusView.title(for: .failed("boom"), bundle: english), "Disk Cleanup Failed")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .failed("boom"), bundle: english), "boom")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .failed("boom"), bundle: english), "Memory Release Failed")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .failed("boom"), bundle: english), "boom")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .unavailable, bundle: english), "Memory Release Not Available")
    }

    func testDiskCleanupStateShowsProgressIndicator() {
        XCTAssertEqual(
            DiskCleanupStatusView.trailingAction(
                isCleaningDiskCleanup: false,
                confirmationState: .inactive,
                bundle: Self.englishBundle
            ),
            .button(title: "Clean", isDestructive: false)
        )
        XCTAssertEqual(
            DiskCleanupStatusView.trailingAction(
                isCleaningDiskCleanup: false,
                confirmationState: .confirming,
                bundle: Self.englishBundle
            ),
            .button(title: "Confirm", isDestructive: true)
        )
        XCTAssertEqual(
            DiskCleanupStatusView.trailingAction(isCleaningDiskCleanup: true, bundle: Self.englishBundle),
            .progressIndicator
        )
        XCTAssertTrue(DiskCleanupStatusView.showsProgressIndicator(for: .scanning))
        XCTAssertTrue(DiskCleanupStatusView.showsProgressIndicator(for: .cleaning))
        XCTAssertFalse(DiskCleanupStatusView.showsProgressIndicator(for: .cleanable(bytes: 512, itemCount: 1, categories: [.userCaches])))
    }

    func testTrashHelperTextMatchesCleanReleasePlan() {
        let cleanableBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 4_096)
        let cleanedBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 8_192)
        let partialBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 12_288)
        let remainingBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 2_048)
        let english = Self.englishBundle

        XCTAssertEqual(TrashCleanupStatusView.title(for: .idle, bundle: english), "Scanning Trash")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .idle, bundle: english), "Checking the current user's Trash.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .scanning, bundle: english), "Scanning Trash")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .scanning, bundle: english), "Checking the current user's Trash.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .clean, bundle: english), "Trash Is Clean")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .clean, bundle: english), "No cleanable Trash items found.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .cleanable(bytes: 4_096, itemCount: 2), bundle: english), "\(cleanableBytes) in Trash")
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(for: .cleanable(bytes: 4_096, itemCount: 2), bundle: english),
            "2 items can be removed after confirmation."
        )
        XCTAssertEqual(TrashCleanupStatusView.title(for: .cleaning, bundle: english), "Cleaning Trash")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .cleaning, bundle: english), "Deleting confirmed Trash contents.")
        XCTAssertEqual(TrashCleanupStatusView.title(for: .cleaned(bytes: 8_192, itemCount: 1), bundle: english), "Cleaned \(cleanedBytes)")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .cleaned(bytes: 8_192, itemCount: 1), bundle: english), "Removed 1 item.")
        XCTAssertEqual(
            TrashCleanupStatusView.title(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048),
                bundle: english
            ),
            "Cleaned \(partialBytes)"
        )
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048),
                bundle: english
            ),
            "Removed 3 items; 1 item could not be deleted. \(remainingBytes) remains."
        )
        XCTAssertEqual(TrashCleanupStatusView.title(for: .failed("denied"), bundle: english), "Trash Cleanup Failed")
        XCTAssertEqual(TrashCleanupStatusView.subtitle(for: .failed("denied"), bundle: english), "denied")
    }

    func testDiskCleanupHelperTextMatchesCleanReleasePlan() {
        let cleanableBytes = DiskCleanupStatusView.byteFormatter.string(fromByteCount: 4_096)
        let cleanedBytes = DiskCleanupStatusView.byteFormatter.string(fromByteCount: 8_192)
        let partialBytes = DiskCleanupStatusView.byteFormatter.string(fromByteCount: 12_288)
        let remainingBytes = DiskCleanupStatusView.byteFormatter.string(fromByteCount: 2_048)
        let english = Self.englishBundle

        XCTAssertEqual(DiskCleanupStatusView.title(for: .idle, bundle: english), "Scanning Disk Cleanup")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .idle, bundle: english), "Checking the selected cleanup scope.")
        XCTAssertEqual(DiskCleanupStatusView.title(for: .scanning, bundle: english), "Scanning Disk Cleanup")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .scanning, bundle: english), "Checking the selected cleanup scope.")
        XCTAssertEqual(DiskCleanupStatusView.title(for: .clean, bundle: english), "Disk Is Clean")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .clean, bundle: english), "No selected disk cleanup items found.")
        XCTAssertEqual(
            DiskCleanupStatusView.title(
                for: .cleanable(bytes: 4_096, itemCount: 2, categories: [.userCaches, .trash, .userLogs]),
                bundle: english
            ),
            "\(cleanableBytes) Cleanable"
        )
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(
                for: .cleanable(bytes: 4_096, itemCount: 2, categories: [.userCaches, .trash, .userLogs]),
                bundle: english
            ),
            "2 items selected from Caches, Trash, Logs."
        )
        XCTAssertEqual(DiskCleanupStatusView.title(for: .cleaning, bundle: english), "Cleaning Disk")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .cleaning, bundle: english), "Deleting selected disk cleanup files.")
        XCTAssertEqual(DiskCleanupStatusView.title(for: .cleaned(bytes: 8_192, itemCount: 1), bundle: english), "Cleaned \(cleanedBytes)")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .cleaned(bytes: 8_192, itemCount: 1), bundle: english), "Removed 1 item.")
        XCTAssertEqual(
            DiskCleanupStatusView.title(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048),
                bundle: english
            ),
            "Cleaned \(partialBytes)"
        )
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048),
                bundle: english
            ),
            "Removed 3 items; 1 item could not be deleted. \(remainingBytes) remains."
        )
        XCTAssertEqual(DiskCleanupStatusView.title(for: .failed("denied"), bundle: english), "Disk Cleanup Failed")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .failed("denied"), bundle: english), "denied")
    }

    func testMemoryHelperTextMatchesCleanReleasePlan() {
        let releasedBytes = MemoryReleaseStatusView.byteFormatter.string(fromByteCount: 65_536)
        let releasableBytes = MemoryReleaseStatusView.byteFormatter.string(fromByteCount: 2_097_152)
        let english = Self.englishBundle

        XCTAssertEqual(MemoryReleaseStatusView.title(for: .idle, bundle: english), "Memory")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .idle, bundle: english), "Release reclaimable system memory.")
        XCTAssertEqual(
            MemoryReleaseStatusView.title(
                for: .usage(percent: 44.4, releasableBytes: 2_097_152),
                bundle: english
            ),
            "\(releasableBytes) Releasable"
        )
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(
                for: .usage(percent: 44.4, releasableBytes: 2_097_152),
                bundle: english
            ),
            "Memory 44%"
        )
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .releasing(previousPercent: 44), bundle: english), "Releasing Memory")
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(for: .releasing(previousPercent: 44), bundle: english),
            "Release reclaimable system memory."
        )
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .released(bytes: 65_536, percentOfTotal: 2.5), bundle: english), "Released \(releasedBytes)")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .released(bytes: 65_536, percentOfTotal: 2.5), bundle: english), "2.5% of total memory")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .unavailable, bundle: english), "Memory Release Not Available")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .unavailable, bundle: english), "No supported memory release method is available on this Mac.")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .failed("boom"), bundle: english), "Memory Release Failed")
        XCTAssertEqual(MemoryReleaseStatusView.subtitle(for: .failed("boom"), bundle: english), "boom")
        XCTAssertEqual(MemoryReleaseStatusView.title(for: .failedToReadMemory, bundle: english), "Memory Reading Failed")
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(for: .failedToReadMemory, bundle: english),
            "Unable to compare before and after memory readings."
        )
    }

    func testProcessActionMessagesMatchCleanReleasePlan() {
        XCTAssertNil(ActiveProcessMemoryList.processActionMessage(for: .idle))
        let english = Self.englishBundle
        XCTAssertEqual(
            ActiveProcessMemoryList.processActionMessage(for: .requested("Safari"), bundle: english),
            "Requested Safari to quit."
        )
        XCTAssertEqual(
            ActiveProcessMemoryList.processActionMessage(for: .notFound("Mail"), bundle: english),
            "Mail is no longer running."
        )
        XCTAssertEqual(
            ActiveProcessMemoryList.processActionMessage(for: .notTerminable("Finder"), bundle: english),
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

    private static func renderedColor<Content: View>(
        of view: Content,
        atTopLeft point: CGPoint
    ) -> NSColor? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        let pixelY = bitmap.pixelsHigh - y - 1

        guard (0..<bitmap.pixelsWide).contains(x),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            return nil
        }

        return bitmap.colorAt(x: x, y: pixelY)?.usingColorSpace(.deviceRGB)
    }

    private static func colorsApproximatelyEqual(
        _ lhs: NSColor,
        _ rhs: NSColor,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
        && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
        && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
        && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    private static func debugColor(_ color: NSColor) -> String {
        String(
            format: "(r: %.3f g: %.3f b: %.3f a: %.3f)",
            color.redComponent,
            color.greenComponent,
            color.blueComponent,
            color.alphaComponent
        )
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
    var releasableByteResults: [UInt64?]
    var releaseResults: [MemoryReleaseResult]

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
        guard currentReadings.isEmpty == false else { return nil }
        return currentReadings.removeFirst()
    }

    func release() async -> MemoryReleaseResult {
        guard releaseResults.isEmpty == false else { return .unavailable }
        return releaseResults.removeFirst()
    }

    func currentReleasableBytes() async -> UInt64? {
        guard releasableByteResults.isEmpty == false else { return nil }
        return releasableByteResults.removeFirst()
    }
}

@MainActor
private final class ViewDiskCleanupServiceRecorder: DiskCleanupServicing {
    var scanResults: [DiskCleanupScanResult]
    var cleanResults: [DiskCleanupResult]

    init(
        scanResults: [DiskCleanupScanResult] = [],
        cleanResults: [DiskCleanupResult] = [.cleaned(bytes: 0, itemCount: 0)]
    ) {
        self.scanResults = scanResults
        self.cleanResults = cleanResults
    }

    func scan(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupScanResult {
        guard scanResults.isEmpty == false else { return .clean }
        return scanResults.removeFirst()
    }

    func clean(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupResult {
        guard cleanResults.isEmpty == false else { return .cleaned(bytes: 0, itemCount: 0) }
        return cleanResults.removeFirst()
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
