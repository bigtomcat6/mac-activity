import XCTest
import AppKit
import SwiftUI
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PreferencesViewTests: XCTestCase {
    func testPreferencesCategoriesHaveStableOrderAndDefaultToGeneral() {
        XCTAssertEqual(
            PreferencesCategory.allCases,
            [.general, .menuBar, .monitoring, .cleanup, .aboutUpdates]
        )
        XCTAssertEqual(PreferencesViewState().selectedCategory, .general)
    }

    func testPreferencesCategoryNavigationDoesNotSavePreferences() {
        let store = InMemoryPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )
        let state = PreferencesViewState()
        let view = PreferencesView(
            preferencesController: controller,
            viewState: state,
            checkForUpdates: {}
        )

        for category in PreferencesCategory.allCases {
            state.selectedCategory = category
            _ = view.body
            XCTAssertEqual(state.selectedCategory, category)
        }

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.load(), .default)
    }

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

    func testPreferencesViewBuildsGeneralPage() {
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

    func testPreferencesViewCanPersistEnergyImpactAppScope() {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            checkForUpdates: {}
        )

        controller.setEnergyImpactAppScope(.regularAndAccessory)

        XCTAssertEqual(controller.state.energyImpactAppScope, .regularAndAccessory)
        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
    }

    func testProcessApplicationIdentifierPreferenceUsesSharedProcessListCopy() {
        let english = AppLocalization.bundle(forLanguageIdentifier: "en")!

        XCTAssertEqual(
            AppLocalization.string(.preferencesProcessApplicationIdentifier, bundle: english),
            "Show application ID in process lists"
        )
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

        XCTAssertEqual(windowController.window?.title, "")
        XCTAssertEqual(windowController.window?.accessibilityLabel(), AppLocalization.string(.appName))
        XCTAssertEqual(windowController.window?.contentViewController is NSHostingController<PreferencesView>, true)
    }

    func testPreferencesWindowUsesFixedWidthAndMinimumHeight() throws {
        _ = NSApplication.shared
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }
        let window = try XCTUnwrap(windowController.window)
        let contentSize = window.contentRect(forFrameRect: window.frame).size

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(contentSize.width, 723, accuracy: 0.5)
        XCTAssertEqual(contentSize.height, 600, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(window.contentView).fittingSize, NSSize(width: 723, height: 470))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone))
    }

    func testPreferencesWindowKeepsFixedWidthDuringNativeZoom() throws {
        _ = NSApplication.shared
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
        window.contentView?.layoutSubtreeIfNeeded()
        let originalSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(try XCTUnwrap(window.contentView).fittingSize, NSSize(width: 723, height: 470))

        window.performZoom(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let zoomedSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertNotEqual(zoomedSize.height, originalSize.height)
        XCTAssertEqual(zoomedSize.width, 723, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(window.contentView).fittingSize, NSSize(width: 723, height: 470))

        window.performZoom(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let restoredSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(restoredSize.width, 723, accuracy: 0.5)
        XCTAssertEqual(restoredSize.height, originalSize.height, accuracy: 0.5)
    }

    func testPreferencesWindowIntegratesTitlebarAndKeepsNativeControls() throws {
        _ = NSApplication.shared
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }
        let window = try XCTUnwrap(windowController.window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.isMovableByWindowBackground)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(type)).isHidden)
        }
    }

    func testPreferencesDetailContentUsesTopChromeAreaAtMinimumHeight() throws {
        _ = NSApplication.shared
        let localization = AppLocalizationController.shared
        let previousLanguage = localization.preferredLanguageIdentifier
        defer { localization.applyPreferredLanguageIdentifier(previousLanguage) }
        localization.applyPreferredLanguageIdentifier("en")
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
        let contentView = try XCTUnwrap(window.contentView)
        for height in [CGFloat(600), 470] {
            window.setContentSize(NSSize(width: 723, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let detailContent = try XCTUnwrap(
                allSubviews(of: contentView).first {
                    String(describing: type(of: $0)).contains("DocumentView")
                }
            )
            let detailContentFrame = detailContent.convert(detailContent.bounds, to: contentView)

            XCTAssertEqual(detailContentFrame.minY, 68, accuracy: 0.5)
        }
    }

    func testSidebarHoverPresentationDoesNotChangeSelection() {
        let state = PreferencesViewState()

        state.hoveredCategory = .menuBar

        XCTAssertEqual(state.selectedCategory, .general)
        XCTAssertEqual(state.hoveredCategory, .menuBar)

        state.hoveredCategory = nil

        XCTAssertNil(state.hoveredCategory)
    }

    func testPreferencesSidebarChromeKeepsControlsInsetWhenResized() throws {
        _ = NSApplication.shared
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

        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.toolbar?.displayMode, .iconOnly)
        XCTAssertTrue(window.toolbar?.items.isEmpty == true)

        for size in [
            NSSize(width: 723, height: 600), NSSize(width: 723, height: 470),
            NSSize(width: 723, height: 780), NSSize(width: 723, height: 600)
        ] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let table = try XCTUnwrap(
                allSubviews(of: window.contentView).compactMap { $0 as? NSTableView }.first
            )
            XCTAssertEqual(table.numberOfRows, PreferencesCategory.allCases.count - 1)
            let firstRowFrame = table.convert(table.rect(ofRow: 0), to: nil)

            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                let frame = button.convert(button.bounds, to: nil)
                XCTAssertFalse(button.isHidden)
                XCTAssertGreaterThanOrEqual(frame.minX, 18)
                XCTAssertGreaterThanOrEqual(frame.minY - firstRowFrame.maxY, 8)
                XCTAssertFalse(frame.intersects(firstRowFrame))
            }
        }
    }

    func testAboutUpdatesRemainsPinnedWhileWindowHeightChanges() throws {
        _ = NSApplication.shared
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
        var bottomOffset: CGFloat?

        for height in [CGFloat(600), 470, 780] {
            window.setContentSize(NSSize(width: 723, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let tables = allSubviews(of: window.contentView).compactMap { $0 as? NSTableView }
            XCTAssertEqual(tables.count, 2)
            let main = try XCTUnwrap(tables.first { $0.numberOfRows == 4 })
            let footer = try XCTUnwrap(tables.first { $0.numberOfRows == 1 })
            let footerFrame = footer.convert(footer.rect(ofRow: 0), to: nil)
            let lastMainRow = main.convert(main.rect(ofRow: main.numberOfRows - 1), to: nil)

            XCTAssertGreaterThanOrEqual(footerFrame.minY, 8)
            XCTAssertLessThanOrEqual(footerFrame.maxY, 60)
            XCTAssertLessThan(footerFrame.maxY, lastMainRow.minY)
            if let bottomOffset {
                XCTAssertEqual(footerFrame.minY, bottomOffset, accuracy: 0.5)
            } else {
                bottomOffset = footerFrame.minY
            }
        }
    }

    func testPinnedAboutUpdatesSharesNativeSidebarSelection() async throws {
        _ = NSApplication.shared
        let store = InMemoryPreferencesStore(initial: .default)
        let controller = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }
        windowController.showWindow(nil)
        let window = try XCTUnwrap(windowController.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<PreferencesView>)
        let tables = allSubviews(of: window.contentView).compactMap { $0 as? NSTableView }
        let main = try XCTUnwrap(tables.first { $0.numberOfRows == 4 })
        let footer = try XCTUnwrap(tables.first { $0.numberOfRows == 1 })

        XCTAssertEqual(main.selectionHighlightStyle, .none)
        XCTAssertEqual(footer.selectionHighlightStyle, .none)

        let aboutSelected = expectation(description: "About selection published")
        let mainSelected = expectation(description: "Main selection published")
        var updatingNativeViews = false
        var publishedSelections: [PreferencesCategory] = []
        let observation = host.rootView.viewState.$selectedCategory.dropFirst().sink {
            XCTAssertFalse(updatingNativeViews)
            publishedSelections.append($0)
            if $0 == .aboutUpdates { aboutSelected.fulfill() }
            if $0 == .menuBar { mainSelected.fulfill() }
        }
        defer { observation.cancel() }

        updatingNativeViews = true
        footer.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        // Check before the deferred SwiftUI selection catches up, not just after layout.
        XCTAssertEqual(footer.selectionHighlightStyle, .none)
        XCTAssertEqual(try XCTUnwrap(footer.rowView(atRow: 0, makeIfNecessary: true)).selectionHighlightStyle, .none)
        window.contentView?.layoutSubtreeIfNeeded()
        updatingNativeViews = false
        await fulfillment(of: [aboutSelected], timeout: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.rootView.viewState.selectedCategory, .aboutUpdates)
        XCTAssertEqual(main.selectedRow, -1)
        XCTAssertEqual(footer.selectedRow, 0)

        updatingNativeViews = true
        main.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(main.selectionHighlightStyle, .none)
        XCTAssertEqual(try XCTUnwrap(main.rowView(atRow: 1, makeIfNecessary: true)).selectionHighlightStyle, .none)
        window.contentView?.layoutSubtreeIfNeeded()
        updatingNativeViews = false
        await fulfillment(of: [mainSelected], timeout: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.rootView.viewState.selectedCategory, .menuBar)
        XCTAssertEqual(main.selectedRow, 1)
        XCTAssertEqual(footer.selectedRow, -1)
        XCTAssertEqual(main.selectionHighlightStyle, .none)
        XCTAssertEqual(footer.selectionHighlightStyle, .none)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(publishedSelections, [.aboutUpdates, .menuBar])
    }

    func testSidebarRapidAndKeyboardSelectionKeepNativeHighlightDisabled() async throws {
        _ = NSApplication.shared
        let store = InMemoryPreferencesStore(initial: .default)
        let controller = PreferencesWindowController(
            preferencesController: PreferencesController(store: store, launchService: NoopLaunchAtLoginService()),
            checkForUpdates: {}
        )
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<PreferencesView>)
        let table = try XCTUnwrap(allSubviews(of: window.contentView)
            .compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 4 })
        let finalSelection = expectation(description: "Rapid selection ends on Menu Bar")
        let keyboardSelection = expectation(description: "Down arrow selects Monitoring")
        let observation = host.rootView.viewState.$selectedCategory.dropFirst().sink {
            if $0 == .menuBar { finalSelection.fulfill() }
            if $0 == .monitoring { keyboardSelection.fulfill() }
        }
        defer { observation.cancel() }

        for row in [3, 0, 3, 1] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertEqual(table.selectionHighlightStyle, .none)
            XCTAssertEqual(try XCTUnwrap(table.rowView(atRow: row, makeIfNecessary: true)).selectionHighlightStyle, .none)
        }
        await fulfillment(of: [finalSelection], timeout: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.rootView.viewState.selectedCategory, .menuBar)
        XCTAssertEqual(table.selectedRow, 1)

        XCTAssertTrue(window.makeFirstResponder(table))
        let downArrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        table.keyDown(with: downArrow)
        await fulfillment(of: [keyboardSelection], timeout: 1)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertEqual(table.selectionHighlightStyle, .none)
        XCTAssertEqual(host.rootView.viewState.selectedCategory, .monitoring)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testPreferencesWindowRetainsCategoryWhenShownAndReopened() throws {
        _ = NSApplication.shared
        let store = InMemoryPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }
        windowController.showWindow(nil)
        let originalWindow = try XCTUnwrap(windowController.window)
        let originalHost = try XCTUnwrap(
            originalWindow.contentViewController as? NSHostingController<PreferencesView>
        )
        let originalState = originalHost.rootView.viewState
        XCTAssertTrue(originalWindow.isVisible)
        XCTAssertEqual(originalState.selectedCategory, .general)

        originalState.selectedCategory = .monitoring
        windowController.showWindow(nil)
        let shownWindow = try XCTUnwrap(windowController.window)
        let shownHost = try XCTUnwrap(
            shownWindow.contentViewController as? NSHostingController<PreferencesView>
        )
        XCTAssertTrue(shownWindow === originalWindow)
        XCTAssertTrue(shownWindow.isVisible)
        XCTAssertTrue(shownHost === originalHost)
        XCTAssertTrue(shownHost.rootView.viewState === originalState)
        XCTAssertEqual(shownHost.rootView.viewState.selectedCategory, .monitoring)
        shownHost.rootView.viewState.hoveredCategory = .menuBar

        shownWindow.close()
        windowController.showWindow(nil)
        let reopenedWindow = try XCTUnwrap(windowController.window)
        let reopenedHost = try XCTUnwrap(
            reopenedWindow.contentViewController as? NSHostingController<PreferencesView>
        )
        XCTAssertTrue(reopenedWindow === originalWindow)
        XCTAssertTrue(reopenedWindow.isVisible)
        XCTAssertTrue(reopenedHost === originalHost)
        XCTAssertTrue(reopenedHost.rootView.viewState === originalState)
        XCTAssertEqual(reopenedHost.rootView.viewState.selectedCategory, .monitoring)
        XCTAssertNil(reopenedHost.rootView.viewState.hoveredCategory)
        XCTAssertEqual(store.saveCount, 0)
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

    func testAboutUpdatesPageRendersChannelPickerWithoutDisclosure() {
        _ = NSApplication.shared
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            viewState: PreferencesViewState(selectedCategory: .aboutUpdates),
            checkForUpdates: {}
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 780, height: 600))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(updateChannelPickerCount(in: window), 1)
    }

    func testAboutUpdatesButtonInvokesExistingCallback() throws {
        _ = NSApplication.shared
        var checkCount = 0
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            viewState: PreferencesViewState(selectedCategory: .aboutUpdates),
            checkForUpdates: { checkCount += 1 }
        )
        .buttonStyle(
            NativeCallbackButtonStyle(title: AppLocalization.string(.preferencesCheckForUpdates))
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 780, height: 600))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            allSubviews(of: window.contentView)
                .compactMap { $0 as? NSButton }
                .first { $0.title == AppLocalization.string(.preferencesCheckForUpdates) }
        )

        button.performClick(nil)

        XCTAssertEqual(checkCount, 1)
    }

    func testPreferencesLanguageChangeRetainsSelectedCategory() throws {
        _ = NSApplication.shared
        let localization = AppLocalizationController.shared
        let previousLanguage = localization.preferredLanguageIdentifier
        defer { localization.applyPreferredLanguageIdentifier(previousLanguage) }
        localization.applyPreferredLanguageIdentifier("en")
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let windowController = PreferencesWindowController(
            preferencesController: controller,
            checkForUpdates: {}
        )
        defer { windowController.close() }
        let window = try XCTUnwrap(windowController.window)
        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<PreferencesView>)
        let state = host.rootView.viewState
        state.selectedCategory = .monitoring
        XCTAssertEqual(AppLocalization.string(state.selectedCategory.titleKey), "Monitoring & Display")

        localization.applyPreferredLanguageIdentifier("zh-Hans")
        _ = host.rootView.body

        XCTAssertEqual(state.selectedCategory, .monitoring)
        XCTAssertEqual(host.rootView.localizationRefreshID, "zh-Hans")
        XCTAssertEqual(window.title, "")
        XCTAssertEqual(
            AppLocalization.string(state.selectedCategory.titleKey),
            "\u{76D1}\u{63A7}\u{4E0E}\u{663E}\u{793A}"
        )
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
        let updateChannelTitles = Set(UpdateChannel.allCases.map {
            AppLocalization.updateChannelTitle(for: $0)
        })
        return allSubviews(of: window.contentView)
            .compactMap { $0 as? NSButton }
            .filter { updateChannelTitles.contains($0.title) }
            .count
    }

    private func allSubviews(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap(allSubviews)
    }
}

private final class InMemoryPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences
    private(set) var saveCount = 0

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        saveCount += 1
        value = preferences
    }
}

// macOS 26's default Form button has no public AppKit or AX action in unit tests.
private struct NativeCallbackButtonStyle: PrimitiveButtonStyle {
    let title: String

    func makeBody(configuration: Configuration) -> some View {
        NativeCallbackButton(title: title) {
            configuration.trigger()
        }
    }
}

private struct NativeCallbackButton: NSViewRepresentable {
    let title: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            action()
        }
    }
}
