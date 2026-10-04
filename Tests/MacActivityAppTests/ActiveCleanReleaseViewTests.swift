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
            diskCleanupService: ViewDiskCleanupServiceRecorder(scanResults: [.clean]),
            appProvider: ViewActiveAppProviderRecorder(entries: Self.entries(count: 2))
        )

        let hostingView = NSHostingView(rootView: ActiveCleanReleaseView(model: model))

        XCTAssertNotNil(hostingView)
    }

    func testPageBodyForwardsProcessDisplayInputs() {
        let model = ActiveCleanupModel(
            diskCleanupService: ViewDiskCleanupServiceRecorder(scanResults: [.clean]),
            appProvider: ViewActiveAppProviderRecorder(entries: Self.entries(count: 2))
        )
        let view = ActiveCleanReleaseView(
            model: model,
            usedMemoryBytes: 4_096,
            showsApplicationIdentifier: false
        )

        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
    }

    func testProcessListBodyForwardsProcessDisplayInputs() async {
        let model = ActiveCleanupModel(
            diskCleanupService: ViewDiskCleanupServiceRecorder(scanResults: [.clean]),
            appProvider: ViewActiveAppProviderRecorder(entries: Self.entries(count: 2))
        )

        await model.refreshVisibleCleanReleaseSections()

        let view = ActiveProcessMemoryList(
            model: model,
            usedMemoryBytes: 4_096,
            showsApplicationIdentifier: false
        )

        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
        XCTAssertNotNil(
            Self.renderedColor(
                of: view.frame(width: 360, height: 120),
                atTopLeft: CGPoint(x: 20, y: 20)
            )
        )
    }

    func testViewActiveAppProviderForwardsTerminationResults() {
        let app = Self.entries(count: 1)[0]
        let provider = ViewActiveAppProviderRecorder(terminationResults: [.requested])

        XCTAssertEqual(provider.requestTermination(app), .requested)
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

        let activeRow = ActiveProcessMemoryRow(app: app, usedMemoryBytes: 1_000, quit: {})
            .frame(width: 360, height: ActiveProcessMemoryLayout.rowHeight)
            .environment(\.appearsActive, true)
        let inactiveRow = ActiveProcessMemoryRow(app: app, usedMemoryBytes: 1_000, quit: {})
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

        let row = ActiveProcessMemoryRow(app: app, usedMemoryBytes: 1_000, quit: {})
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

        let row = ActiveProcessMemoryRow(app: app, usedMemoryBytes: 1_000, quit: {})
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

    func testProcessIdentifierTextCanBeHiddenByPreference() {
        let app = ActiveAppMemoryEntry(
            processIdentifier: 2_104,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            residentMemoryBytes: 1_024,
            isTerminable: true
        )
        let fallbackApp = ActiveAppMemoryEntry(
            processIdentifier: 2_105,
            name: "Helper",
            bundleIdentifier: nil,
            residentMemoryBytes: 1_024,
            isTerminable: true
        )

        XCTAssertEqual(
            ActiveProcessMemoryRow.identifierText(
                for: app,
                showsApplicationIdentifier: true,
                bundle: Self.englishBundle
            ),
            "com.apple.Safari"
        )
        XCTAssertEqual(
            ActiveProcessMemoryRow.identifierText(
                for: fallbackApp,
                showsApplicationIdentifier: true,
                bundle: Self.englishBundle
            ),
            "Process 2,105"
        )
        XCTAssertNil(
            ActiveProcessMemoryRow.identifierText(
                for: app,
                showsApplicationIdentifier: false,
                bundle: Self.englishBundle
            )
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

        XCTAssertEqual(DiskCleanupStatusView.title(for: .failed(.message("boom")), bundle: english), "Disk Cleanup Failed")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .failed(.message("boom")), bundle: english), "boom")
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
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(
                for: .partial(bytes: 12_288, deletedCount: 1, failedCount: 2, remainingBytes: nil),
                bundle: english
            ),
            "Removed 1 item; 2 items could not be deleted."
        )
        XCTAssertEqual(DiskCleanupStatusView.title(for: .failed(.message("denied")), bundle: english), "Disk Cleanup Failed")
        XCTAssertEqual(DiskCleanupStatusView.subtitle(for: .failed(.message("denied")), bundle: english), "denied")
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(for: .failed(.unableToDeleteItems), bundle: english),
            "Unable to delete selected disk cleanup items."
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

        let pixelX = Int(point.x.rounded(.down))
        let sourceY = Int(point.y.rounded(.down))
        let pixelY = bitmap.pixelsHigh - sourceY - 1

        guard (0..<bitmap.pixelsWide).contains(pixelX),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            return nil
        }

        return bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
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

    func requestTermination(_: ActiveAppMemoryEntry) -> ActiveAppTerminationResult {
        guard terminationResults.isEmpty == false else { return .notFound }
        return terminationResults.removeFirst()
    }
}
