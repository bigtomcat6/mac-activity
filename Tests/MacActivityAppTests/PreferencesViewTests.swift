import XCTest
import AppKit
import SwiftUI
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PreferencesViewTests: XCTestCase {
    func testVersionInfoDisplayTextIncludesBuildWhenPresent() {
        let info = PreferencesVersionInfo(shortVersion: "26.0.0-alpha.2", build: "7")

        XCTAssertEqual(info.displayText, "26.0.0-alpha.2 (7)")
    }

    func testVersionInfoDisplayTextOmitsBlankBuild() {
        let info = PreferencesVersionInfo(shortVersion: "26.0.1", build: " ")

        XCTAssertEqual(info.displayText, "26.0.1")
    }

    func testCurrentVersionPrefersPrereleaseReleaseTag() throws {
        let bundle = try makeBundle(info: [
            "CFBundleExecutable": "Mac Activity",
            "CFBundleIdentifier": "com.how.macactivity.test",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Mac Activity",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "26.0.0",
            "CFBundleVersion": "2",
            "MacActivityReleaseTag": "v26.0.0-alpha.2"
        ])
        let info = PreferencesVersionInfo.current(bundle: bundle)

        XCTAssertEqual(info.displayText, "v26.0.0-alpha.2")
    }

    func testCurrentVersionKeepsBuildWhenReleaseTagMatchesShortVersion() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "26.0.0",
            "CFBundleVersion": "4",
            "MacActivityReleaseTag": "v26.0.0"
        ])

        let info = PreferencesVersionInfo.current(bundle: bundle)

        XCTAssertEqual(info.displayText, "26.0.0 (4)")
    }

    func testCurrentVersionIgnoresPlaceholderReleaseTag() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "26.0.0",
            "CFBundleVersion": "5",
            "MacActivityReleaseTag": "$(MACACTIVITY_RELEASE_TAG)"
        ])

        let info = PreferencesVersionInfo.current(bundle: bundle)

        XCTAssertEqual(info.displayText, "26.0.0 (5)")
    }

    func testCurrentVersionUsesShortVersionWhenReleaseTagIsMissing() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "26.0.1"
        ])

        let info = PreferencesVersionInfo.current(bundle: bundle)

        XCTAssertEqual(info.displayText, "26.0.1")
    }

    func testPreferencesViewBuildsUpdateHeader() {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            versionInfo: PreferencesVersionInfo(shortVersion: "26.0.0", build: "5"),
            checkForUpdates: {}
        )

        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
    }

    func testPreferencesViewBuildsExpandedUpdateChannelPickerAndPersistsSelection() {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            versionInfo: PreferencesVersionInfo(shortVersion: "26.0.0", build: "5"),
            isUpdateChannelExpanded: true,
            checkForUpdates: {}
        )

        controller.setUpdateChannel(.alpha)

        XCTAssertEqual(controller.state.updateChannel, .alpha)
        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
    }

    func testPreferencesViewBuildsDefaultCollapsedUpdateStateAndUpdateChannelOptions() {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            checkForUpdates: {}
        )

        view.toggleUpdateChannelExpanded()
        XCTAssertFalse(String(describing: type(of: view.updateChannelOption(for: .release))).isEmpty)
        XCTAssertFalse(String(describing: type(of: view.updateChannelOption(for: .beta))).isEmpty)
        XCTAssertFalse(String(describing: type(of: view.updateChannelOption(for: .alpha))).isEmpty)
        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
    }

    func testPreferencesViewRefreshIDFollowsSelectedLanguage() {
        defer { AppLocalizationController.shared.applyPreferredLanguageIdentifier(nil) }
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            checkForUpdates: {}
        )

        AppLocalizationController.shared.applyPreferredLanguageIdentifier("zh-Hans")

        XCTAssertEqual(view.localizationRefreshID, "zh-Hans")
    }

    func testPreferencesViewCanPersistProcessApplicationIdentifierToggle() {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            checkForUpdates: {}
        )

        controller.setShowsProcessApplicationIdentifier(true)

        XCTAssertTrue(controller.state.showsProcessApplicationIdentifier)
        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
    }

    func testPreferencesWindowControllerHostsPreferencesView() {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )

        XCTAssertEqual(windowController.window?.title, AppLocalization.string(.preferences))
        XCTAssertEqual(windowController.window?.contentViewController is NSHostingController<PreferencesView>, true)
    }

    func testPreferencesWindowControllerCollapsesRenderedUpdateChannelAfterCloseAndReopen() throws {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }

        windowController.showWindow(nil)
        let window = try XCTUnwrap(windowController.window)
        let hostingController = try XCTUnwrap(window.contentViewController as? NSHostingController<PreferencesView>)
        XCTAssertEqual(updateChannelPickerCount(in: window), 0)

        hostingController.rootView.toggleUpdateChannelExpanded()
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(updateChannelPickerCount(in: window), 1)

        window.close()
        windowController.showWindow(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(updateChannelPickerCount(in: window), 0)
    }

    func testPreferencesWindowControllerKeepsHostedSettingsPageWhenReopening() throws {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }

        windowController.showWindow(nil)
        let window = try XCTUnwrap(windowController.window)
        let contentViewController = try XCTUnwrap(window.contentViewController)

        window.close()
        windowController.showWindow(nil)

        XCTAssertTrue(window.contentViewController === contentViewController)
    }

    func testPreferencesWindowControllerKeepsUpdateChannelExpandedWhenAlreadyVisible() throws {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }

        windowController.showWindow(nil)
        let window = try XCTUnwrap(windowController.window)
        let hostingController = try XCTUnwrap(window.contentViewController as? NSHostingController<PreferencesView>)
        hostingController.rootView.toggleUpdateChannelExpanded()
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(updateChannelPickerCount(in: window), 1)

        windowController.showWindow(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(updateChannelPickerCount(in: window), 1)
    }

    private func makeBundle(info: [String: String]) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist = NSMutableDictionary(dictionary: [
            "CFBundleExecutable": "Mac Activity",
            "CFBundleIdentifier": "com.how.macactivity.test",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Mac Activity",
            "CFBundlePackageType": "APPL"
        ])
        infoPlist.addEntries(from: info)
        XCTAssertTrue(infoPlist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func updateChannelPickerCount(in window: NSWindow) -> Int {
        allSubviews(of: window.contentView)
            .compactMap { $0 as? NSPopUpButton }
            .filter { $0.itemTitles.contains(AppLocalization.updateChannelTitle(for: .alpha)) }
            .count
    }

    private func allSubviews(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap(allSubviews)
    }
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
