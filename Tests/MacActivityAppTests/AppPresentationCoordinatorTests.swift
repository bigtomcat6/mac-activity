import AppKit
import XCTest
@testable import MacActivityApp

@MainActor
final class AppPresentationCoordinatorTests: XCTestCase {
    func testInitialLaunchAlwaysInstallsStatusItemImmediately() {
        let recorder = EventRecorder()
        let coordinator = AppPresentationCoordinator(
            statusItemController: RecordingStatusItemController(recorder: recorder),
            activationController: RecordingActivationController(recorder: recorder)
        )

        coordinator.configureInitialState()

        XCTAssertEqual(recorder.events, [
            "install",
            "activation:accessory"
        ])
    }

    func testAppMainMenuExposesSettingsAndQuitShortcuts() throws {
        let target = MainMenuActionTarget()
        let menu = AppMainMenu.make(
            appName: "MacActivity",
            preferencesTitle: "Settings…",
            quitTitle: "Quit",
            target: target,
            preferencesAction: #selector(MainMenuActionTarget.openPreferences(_:)),
            quitAction: #selector(MainMenuActionTarget.quit(_:))
        )

        XCTAssertEqual(menu.items.count, 1)
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(appMenu.title, "MacActivity")
        XCTAssertEqual(appMenu.items.count, 3)
        XCTAssertEqual(appMenu.items[0].title, "Settings…")
        XCTAssertEqual(appMenu.items[0].keyEquivalent, ",")
        XCTAssertEqual(appMenu.items[0].keyEquivalentModifierMask, [.command])
        XCTAssertTrue(appMenu.items[0].target === target)
        XCTAssertEqual(appMenu.items[0].action, #selector(MainMenuActionTarget.openPreferences(_:)))
        XCTAssertTrue(appMenu.items[1].isSeparatorItem)
        XCTAssertEqual(appMenu.items[2].title, "Quit")
        XCTAssertEqual(appMenu.items[2].keyEquivalent, "q")
        XCTAssertEqual(appMenu.items[2].keyEquivalentModifierMask, [.command])
        XCTAssertTrue(appMenu.items[2].target === target)
        XCTAssertEqual(appMenu.items[2].action, #selector(MainMenuActionTarget.quit(_:)))
    }

    func testAppDelegateInstallsHiddenMainMenu() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/MacActivityApp/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("NSApp.mainMenu = AppMainMenu.make("))
        XCTAssertTrue(source.contains("installMainMenu()"))
    }
}

@MainActor
private final class EventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@MainActor
private final class RecordingStatusItemController: StatusItemControlling {
    private let recorder: EventRecorder

    init(recorder: EventRecorder) {
        self.recorder = recorder
    }

    func install() {
        recorder.record("install")
    }
}

@MainActor
private final class RecordingActivationController: ApplicationActivationControlling {
    private let recorder: EventRecorder

    init(recorder: EventRecorder) {
        self.recorder = recorder
    }

    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        switch policy {
        case .accessory:
            recorder.record("activation:accessory")
        case .regular:
            recorder.record("activation:regular")
        case .prohibited:
            recorder.record("activation:prohibited")
        @unknown default:
            recorder.record("activation:unknown")
        }
    }
}

private final class MainMenuActionTarget: NSObject {
    @objc func openPreferences(_ sender: Any?) {}
    @objc func quit(_ sender: Any?) {}
}
