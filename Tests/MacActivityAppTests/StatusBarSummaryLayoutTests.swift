import AppKit
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class StatusBarSummaryLayoutTests: XCTestCase {
    func testImagePresentationUsesTwoLineStatusBarImage() {
        let items = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓15.4K", style: .network)
        ]

        let presentation = StatusBarSummaryLayout.imagePresentation(
            summaryText: "fallback",
            items: items
        )

        XCTAssertEqual(presentation.accessibilityTitle, "CPU 7% | MEM 38% | ↑13.8K ↓15.4K")
        XCTAssertEqual(presentation.image.size.height, StatusBarSummaryLayout.statusBarHeight)
        XCTAssertEqual(presentation.image.size.width, StatusBarSummaryLayout.preferredWidth(for: items))
        XCTAssertGreaterThanOrEqual(presentation.length, 44)
        XCTAssertTrue(presentation.image.isTemplate)
    }

    func testImagePresentationUsesFallbackTextWhenNoStructuredItemsExist() {
        let presentation = StatusBarSummaryLayout.imagePresentation(
            summaryText: "Metrics",
            items: []
        )

        XCTAssertEqual(presentation.accessibilityTitle, "Metrics")
        XCTAssertEqual(presentation.image.size.height, StatusBarSummaryLayout.statusBarHeight)
        XCTAssertEqual(presentation.image.size.width, presentation.length)
        XCTAssertGreaterThanOrEqual(presentation.length, 44)
    }

    func testPreferredWidthUsesDeterministicColumnsAndSeparators() {
        let items = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓15.4K", style: .network)
        ]

        XCTAssertLessThanOrEqual(StatusBarSummaryLayout.preferredWidth(for: items), 154)
        XCTAssertEqual(StatusBarSummaryLayout.preferredWidth(for: []), 0)
    }

    func testFontsUseReadableStatusBarSizes() {
        XCTAssertEqual(StatusBarSummaryLayout.primaryFont(for: .metric).pointSize, 10)
        XCTAssertEqual(StatusBarSummaryLayout.secondaryFont(for: .metric).pointSize, 6)
        XCTAssertEqual(StatusBarSummaryLayout.primaryFont(for: .network).pointSize, 8)
        XCTAssertEqual(StatusBarSummaryLayout.secondaryFont(for: .network).pointSize, 8)
    }

    func testStatusItemThrottlesValueRendersToTwoSeconds() {
        XCTAssertEqual(StatusItemController.summaryUpdateInterval, .seconds(2))
    }

    func testStatusBarLabelsUseBoldWeightAndValuesUseHeavyWeight() {
        XCTAssertEqual(NSFontManager.shared.weight(of: StatusBarSummaryLayout.fallbackFont), 9)
        XCTAssertEqual(NSFontManager.shared.weight(of: StatusBarSummaryLayout.primaryFont(for: .metric)), 10)
        XCTAssertEqual(NSFontManager.shared.weight(of: StatusBarSummaryLayout.secondaryFont(for: .metric)), 9)
        XCTAssertEqual(NSFontManager.shared.weight(of: StatusBarSummaryLayout.primaryFont(for: .network)), 10)
        XCTAssertEqual(NSFontManager.shared.weight(of: StatusBarSummaryLayout.secondaryFont(for: .network)), 10)
    }

    func testItemWidthIsStableForNetworkMetricAcrossDifferentValues() {
        let slower = StatusSummaryItem(
            kind: .network,
            primaryText: "↑512B",
            secondaryText: "↓999B",
            style: .network
        )
        let faster = StatusSummaryItem(
            kind: .network,
            primaryText: "↑13.8K",
            secondaryText: "↓125.4M",
            style: .network
        )

        XCTAssertEqual(
            StatusBarSummaryLayout.itemWidth(for: slower),
            StatusBarSummaryLayout.itemWidth(for: faster)
        )
    }

    func testFanMetricGetsHalfDigitMoreWidthThanDefaultMetricColumn() {
        let fan = StatusSummaryItem(
            kind: .fan,
            primaryText: "9999",
            secondaryText: "RPM",
            style: .metric
        )
        let primaryWidth = ("9999" as NSString).size(
            withAttributes: [.font: StatusBarSummaryLayout.primaryFont(for: .metric)]
        ).width
        let secondaryWidth = ("RPM" as NSString).size(
            withAttributes: [.font: StatusBarSummaryLayout.secondaryFont(for: .metric)]
        ).width
        let baseFanWidth = ceil(
            max(StatusBarSummaryLayout.metricMinimumWidth, max(primaryWidth, secondaryWidth))
        )
        let halfDigitWidth = ceil(
            ("0" as NSString).size(
                withAttributes: [.font: StatusBarSummaryLayout.primaryFont(for: .metric)]
            ).width / 2
        )

        XCTAssertEqual(
            StatusBarSummaryLayout.itemWidth(for: fan),
            baseFanWidth + halfDigitWidth,
            accuracy: 0.5
        )
    }

    func testPreferredWidthIsStableForSameMetricSelectionAcrossDifferentValues() {
        let quieterItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "41℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑512B", secondaryText: "↓999B", style: .network)
        ]
        let busierItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "100%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "105℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓125.4M", style: .network)
        ]

        XCTAssertEqual(
            StatusBarSummaryLayout.preferredWidth(for: quieterItems),
            StatusBarSummaryLayout.preferredWidth(for: busierItems)
        )
    }

    func testImagePresentationWidthIsStableForSameMetricSelectionAcrossDifferentValues() {
        let quieterItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "41℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑512B", secondaryText: "↓999B", style: .network)
        ]
        let busierItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "100%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "105℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓125.4M", style: .network)
        ]

        XCTAssertEqual(
            StatusBarSummaryLayout.imagePresentation(summaryText: "quiet", items: quieterItems).length,
            StatusBarSummaryLayout.imagePresentation(summaryText: "busy", items: busierItems).length
        )
    }

    func testStructureKeyChangesWhenMenuBarMetricSelectionChanges() {
        let cpuAndMemory = [
            StatusSummaryItem(kind: .cpu, primaryText: "--", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "--", secondaryText: "MEM", style: .metric)
        ]
        let cpuAndNetwork = [
            StatusSummaryItem(kind: .cpu, primaryText: "--", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑--", secondaryText: "↓--", style: .network)
        ]

        XCTAssertNotEqual(
            StatusBarSummaryStructureKey(items: cpuAndMemory),
            StatusBarSummaryStructureKey(items: cpuAndNetwork)
        )
    }

    func testStructureKeyIgnoresValueOnlyChanges() {
        let quieterItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric)
        ]
        let busierItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "98%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "88%", secondaryText: "MEM", style: .metric)
        ]

        XCTAssertEqual(
            StatusBarSummaryStructureKey(items: quieterItems),
            StatusBarSummaryStructureKey(items: busierItems)
        )
    }

    func testStatusItemRightClickClassificationOnlyMatchesRightMouseUp() {
        XCTAssertTrue(StatusItemController.presentsContextMenu(for: .rightMouseUp))
        XCTAssertFalse(StatusItemController.presentsContextMenu(for: .leftMouseUp))
        XCTAssertFalse(StatusItemController.presentsContextMenu(for: .leftMouseDown))
        XCTAssertFalse(StatusItemController.presentsContextMenu(for: .rightMouseDown))
        XCTAssertFalse(StatusItemController.presentsContextMenu(for: nil))
    }

    func testStatusItemContextMenuContainsPreferencesSeparatorAndQuit() {
        let target = ContextMenuActionTarget()
        let menu = StatusItemController.makeContextMenu(
            preferencesTitle: "Settings…",
            quitTitle: "Quit",
            target: target,
            preferencesAction: #selector(ContextMenuActionTarget.openPreferences(_:)),
            quitAction: #selector(ContextMenuActionTarget.quit(_:))
        )

        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.items[0].title, "Settings…")
        XCTAssertEqual(menu.items[0].keyEquivalent, "")
        XCTAssertTrue(menu.items[0].target === target)
        XCTAssertEqual(menu.items[0].action, #selector(ContextMenuActionTarget.openPreferences(_:)))
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "Quit")
        XCTAssertEqual(menu.items[2].keyEquivalent, "")
        XCTAssertTrue(menu.items[2].target === target)
        XCTAssertEqual(menu.items[2].action, #selector(ContextMenuActionTarget.quit(_:)))
    }

    func testStatusItemContextMenuActionsForwardToInjectedClosures() {
        var preferencesCalls = 0
        var quitCalls = 0
        let controller = makeStatusItemController(
            showPreferences: { preferencesCalls += 1 },
            quitApplication: { quitCalls += 1 }
        )

        controller.contextMenuPreferences(nil)
        controller.contextMenuQuit(nil)

        XCTAssertEqual(preferencesCalls, 1)
        XCTAssertEqual(quitCalls, 1)
    }

    func testStatusItemLeftClickTogglesPopoverAndRightClickPresentsContextMenu() {
        let popover = RecordingPopoverController()
        var preferencesCalls = 0
        var quitCalls = 0
        let controller = makeStatusItemController(
            popoverController: popover,
            showPreferences: { preferencesCalls += 1 },
            quitApplication: { quitCalls += 1 }
        )
        controller.install()
        defer { controller.remove() }

        controller.handleStatusItemClick(eventType: .leftMouseUp)

        XCTAssertEqual(popover.toggleCount, 1)
        XCTAssertNotNil(popover.lastView)
        XCTAssertEqual(preferencesCalls, 0)
        XCTAssertEqual(quitCalls, 0)

        let trackedMenu = ContextMenuTrackingBox()
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { notification in
            trackedMenu.record(notification.object)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            trackedMenu.cancel()
        }

        controller.handleStatusItemClick(eventType: .rightMouseUp)
        NotificationCenter.default.removeObserver(observer)

        XCTAssertEqual(popover.toggleCount, 1)
        XCTAssertEqual(preferencesCalls, 0)
        XCTAssertEqual(quitCalls, 0)

        let menu = trackedMenu.menu
        XCTAssertEqual(menu?.items.count, 3)
        XCTAssertEqual(menu?.items.first?.title, AppLocalization.string(.preferences))
        XCTAssertTrue(menu?.items.dropFirst().first?.isSeparatorItem == true)
        XCTAssertEqual(menu?.items.last?.title, AppLocalization.string(.quit))
    }

    func testStatusItemRightClickBeforeInstallDoesNotPresentMenu() {
        let popover = RecordingPopoverController()
        let controller = makeStatusItemController(popoverController: popover)

        controller.handleStatusItemClick(eventType: .rightMouseUp)

        XCTAssertEqual(popover.toggleCount, 0)
    }

    private func makeStatusItemController(
        popoverController: DashboardPopoverControlling = RecordingPopoverController(),
        showPreferences: @escaping () -> Void = {},
        quitApplication: @escaping () -> Void = {}
    ) -> StatusItemController {
        let store = MetricsStore(
            snapshot: MetricsSnapshot(
                timestamp: Date(timeIntervalSince1970: 0),
                cpu: CPUReading(usagePercent: 12)
            )
        )
        let preferences = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        return StatusItemController(
            summaryModel: StatusSummaryModel(store: store, preferences: preferences),
            popoverController: popoverController,
            showPreferences: showPreferences,
            quitApplication: quitApplication
        )
    }
}

private final class ContextMenuActionTarget: NSObject {
    @objc func openPreferences(_ sender: Any?) {}
    @objc func quit(_ sender: Any?) {}
}

private final class InMemoryPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        value = preferences
    }
}

@MainActor
private final class RecordingPopoverController: DashboardPopoverControlling {
    private(set) var toggleCount = 0
    private(set) var lastView: NSView?

    func toggle(relativeTo view: NSView?) {
        toggleCount += 1
        lastView = view
    }
}

/// Lock-protected so the `@Sendable` notification observer can hand the
/// tracked menu back to the main-actor test safely.
private final class ContextMenuTrackingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMenu: NSMenu?

    func record(_ object: Any?) {
        guard let menu = object as? NSMenu else { return }
        lock.lock()
        storedMenu = menu
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let menu = storedMenu
        lock.unlock()
        menu?.cancelTracking()
    }

    var menu: NSMenu? {
        lock.lock()
        defer { lock.unlock() }
        return storedMenu
    }
}
