import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardGlassNavigationTests: XCTestCase {
    // Actual Dashboard buttons must tear down Audio before a rapid re-entry; repeat presses are inert.
    func testDashboardButtonsPreserveRapidAudioLifecycle() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Glass requires macOS 26") }
        let coordinator = TestAudioControlCoordinator()
        let audio = AudioDashboardModel(coordinator: coordinator)
        let selection = DashboardTabSelectionState(initialTab: .audio)
        let host = NSHostingView(rootView: DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: PreferencesController(store: PreferencesStoreFake(), launchService: NoopLaunchAtLoginService()),
            audioDashboardModel: audio, tabSelectionState: selection)
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._accessibilityReduceMotion, false)
            .environment(\.dashboardPresentationIsPresented, true))
        let window = fixture(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(coordinator.refreshSystemAudioAuthorizationCallCount, 1)
        func press(_ index: Int) throws {
            let buttons = Self.views(host).compactMap { $0 as? NSButton }
                .filter { $0.accessibilityRole() == .radioButton }
                .sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
            XCTAssertEqual(buttons.count, 4)
            XCTAssertTrue(try XCTUnwrap(buttons.indices.contains(index) ? buttons[index] : nil).accessibilityPerformPress())
            host.layoutSubtreeIfNeeded()
        }
        try press(0)
        try await Task.sleep(for: .milliseconds(30)) // Well inside the old 280ms animation boundary.
        XCTAssertEqual(selection.selectedTab, .overview)
        await audio.applicationDidBecomeActive()
        XCTAssertEqual(coordinator.refreshSystemAudioAuthorizationCallCount, 1, "Audio must already be deactivated")
        try press(3)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(selection.selectedTab, .audio)
        XCTAssertEqual(coordinator.refreshSystemAudioAuthorizationCallCount, 2)
        try press(3)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.refreshSystemAudioAuthorizationCallCount, 2, "Selected-tab guard must not reactivate Audio")
        await audio.applicationDidBecomeActive()
        XCTAssertEqual(coordinator.refreshSystemAudioAuthorizationCallCount, 3)
        XCTAssertEqual(coordinator.shutdownCallCount, 0)
    }

    // Catches a navigation animation escaping into the page owner's binding transaction.
    func testGlassSelectionWritesUnanimatedExternalBinding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Glass requires macOS 26") }
        let state = GlassNavigationTestState()
        let host = NSHostingView(rootView: VStack {
            GlassNavigationTestFixture(state: state)
            GlassPageTransactionProbe(state: state)
        }.environment(\._accessibilityReduceTransparency, false))
        let window = fixture(host)
        defer { window.close() }
        let buttons = Self.views(host).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        guard buttons.count == 4 else { return }
        state.pageTransactions.removeAll()
        XCTAssertTrue(buttons[1].accessibilityPerformPress())
        settle(host)
        XCTAssertEqual(state.selection, .actives)
        XCTAssertEqual(state.changes, [.actives])
        XCTAssertFalse(state.pageTransactions.isEmpty)
        XCTAssertTrue(state.pageTransactions.allSatisfy { $0.animation == nil }, "The sibling page must not inherit the lens animation")
    }

    func testGlassFixtureOverridesOuterOpaqueEnvironment() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Glass requires macOS 26") }
        let host = NSHostingView(rootView: GlassNavigationTestFixture(state: GlassNavigationTestState())
            .environment(\._accessibilityReduceTransparency, true)
            .environment(\._accessibilityReduceMotion, true))
        let window = fixture(host)
        defer { window.close() }
        XCTAssertEqual(Self.views(host).compactMap { $0 as? NSSegmentedControl }.count, 0)
        XCTAssertEqual(Self.views(host).compactMap { $0 as? NSButton }.count, 4)
    }
    // Catches duplicate actions, missing selection semantics and inaccessible custom buttons.
    func testGlassNavigationAccessibleSelectionAndRepeatPress() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Glass requires macOS 26") }
        let state = GlassNavigationTestState()
        let host = NSHostingView(rootView: GlassNavigationTestFixture(state: state))
        let window = fixture(host)
        defer { window.close() }
        for target in [0, 1, 1, 2, 3, 0] {
            let buttons = Self.views(host).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 4)
            guard buttons.count == 4 else { return }
            XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, DashboardTab.allCases.map(\.title))
            XCTAssertEqual(buttons.map(\.toolTip), DashboardTab.allCases.map(\.title))
            XCTAssertTrue(buttons[target].accessibilityPerformPress())
            settle(host)
            XCTAssertEqual(state.selection, DashboardTab.allCases[target])
            let selected = buttons.filter { ($0.accessibilityValue() as? NSNumber)?.boolValue == true }
            XCTAssertEqual(selected.count, 1, "Exactly one navigation item must expose selected state")
            XCTAssertEqual((buttons[target].accessibilityValue() as? NSNumber)?.boolValue, true)
            // App-hosted SwiftUI exposes these native cells. SwiftPM's hosting root is empty.
            let exposed = buttons.compactMap(\.cell)
            XCTAssertEqual(exposed.map { $0.accessibilityLabel() }, DashboardTab.allCases.map(\.title))
            XCTAssertTrue(exposed.allSatisfy { $0.accessibilityRole() == .radioButton })
            XCTAssertEqual(exposed.filter { ($0.accessibilityValue() as? NSNumber)?.boolValue == true }.count, 1)
            XCTAssertEqual((exposed[target].accessibilityValue() as? NSNumber)?.boolValue, true)
        }
        XCTAssertEqual(state.changes, [.actives, .energyImpact, .audio, .overview])
        XCTAssertEqual(host.fittingSize.width, 126, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, 28, accuracy: 1)
        let buttons = Self.views(host).compactMap { $0 as? NSButton }.sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
        XCTAssertTrue(window.makeFirstResponder(buttons[0]))
        XCTAssertTrue(buttons.allSatisfy { $0.focusRingType == .exterior }, "Borderless navigation must explicitly enable the native focus ring")
        func key(_ text: String, _ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            window.firstResponder?.keyDown(with: event)
            settle(host)
        }
        try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124)
        XCTAssertTrue(window.firstResponder === buttons[1])
        XCTAssertEqual(state.selection, .overview, "Arrows move focus, not selection")
        try key(" ", 49)
        try key(" ", 49)
        XCTAssertEqual(state.selection, .actives)
        XCTAssertEqual(state.changes.count, 5)
        try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124)
        try key("\r", 36)
        try key("\r", 36)
        XCTAssertEqual(state.selection, .energyImpact)
        XCTAssertEqual(state.changes.count, 6)
        try key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123)
        XCTAssertTrue(window.firstResponder === buttons[1])
        try key("\r", 36)
        XCTAssertEqual(state.selection, .actives)
        XCTAssertEqual(state.changes.count, 7)
        try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124)
        state.motion = true
        settle(host)
        XCTAssertTrue(window.firstResponder === buttons[2], "Changing Reduce Motion must not destroy native focus")
        state.selection = .audio
        settle(host)
        XCTAssertEqual(Self.views(host).compactMap { $0 as? NSButton }.count, 4)
    }

    func testGlassNavigationFourSymbolMapsAndOpaqueAccessibilityRoute() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Glass requires macOS 26") }
        for opaque in [false, true] {
            for selected in 0..<4 {
                let host = NSHostingView(rootView: DashboardTabPicker(selection: .constant(DashboardTab.allCases[selected]))
                    .environment(\._accessibilityReduceTransparency, opaque)
                    .environment(\._accessibilityReduceMotion, true).fixedSize())
                let window = fixture(host)
                defer { window.close() }
                let views = Self.views(host)
                XCTAssertEqual(views.compactMap { $0 as? NSSegmentedControl }.count, opaque ? 1 : 0)
                let icons = views.compactMap { $0 as? NSImageView }
                XCTAssertEqual(icons.count, 4)
                for (i, icon) in icons.enumerated() {
                    let name = ["square.grid.2x2", "list.bullet.rectangle", "bolt", "speaker.wave.2"][i]
                    let expected = NSImage(systemSymbolName: name + (i == selected ? ".fill" : ""), accessibilityDescription: DashboardTab.allCases[i].title)
                    XCTAssertEqual(icon.image?.tiffRepresentation, expected?.tiffRepresentation)
                    XCTAssertTrue(icon.isAccessibilityHidden())
                    XCTAssertNil(icon.hitTest(.zero))
                }
            }
        }
    }

    private func fixture(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 220, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        settle(host)
        return window
    }

    private func settle(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }

    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

}

@MainActor
private final class GlassNavigationTestState: ObservableObject {
    @Published var selection: DashboardTab = .overview
    @Published var motion = false
    var changes: [DashboardTab] = []
    var pageTransactions: [Transaction] = []
}

private struct GlassPageTransactionProbe: View {
    @ObservedObject var state: GlassNavigationTestState
    var body: some View {
        Text(state.selection.title).transaction { state.pageTransactions.append($0) }
    }
}

private struct GlassNavigationTestFixture: View {
    @ObservedObject var state: GlassNavigationTestState
    var body: some View {
        DashboardTabPicker(selection: Binding(get: { state.selection }, set: { state.selection = $0; state.changes.append($0) }))
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._accessibilityReduceMotion, state.motion).fixedSize()
    }
}
