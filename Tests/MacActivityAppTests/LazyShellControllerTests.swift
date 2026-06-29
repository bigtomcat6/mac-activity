import AppKit
import XCTest
@testable import MacActivityApp

@MainActor
final class LazyShellControllerTests: XCTestCase {
    func testLazyDashboardPopoverControllerDefersConstructionUntilToggle() {
        let recorder = LazyControllerEventRecorder()
        let controller = LazyDashboardPopoverController {
            recorder.record("create-popover")
            return RecordingDashboardPopoverController(recorder: recorder)
        }

        XCTAssertEqual(recorder.events, [])

        controller.toggle(relativeTo: nil)

        XCTAssertEqual(recorder.events, [
            "create-popover",
            "toggle-popover"
        ])
    }

    func testLazyDashboardPopoverControllerReusesConstructedPopoverController() {
        let recorder = LazyControllerEventRecorder()
        let controller = LazyDashboardPopoverController {
            recorder.record("create-popover")
            return RecordingDashboardPopoverController(recorder: recorder)
        }

        controller.toggle(relativeTo: nil)
        controller.toggle(relativeTo: nil)

        XCTAssertEqual(recorder.events, [
            "create-popover",
            "toggle-popover",
            "toggle-popover"
        ])
    }

    func testLazyDashboardPopoverControllerRecreatesPopoverAfterReset() {
        let recorder = LazyControllerEventRecorder()
        let controller = LazyDashboardPopoverController {
            recorder.record("create-popover")
            return RecordingDashboardPopoverController(recorder: recorder)
        }

        controller.toggle(relativeTo: nil)
        controller.reset()
        controller.toggle(relativeTo: nil)

        XCTAssertEqual(recorder.events, [
            "create-popover",
            "toggle-popover",
            "create-popover",
            "toggle-popover"
        ])
    }

    func testLazyPreferencesWindowControllerDefersConstructionUntilShowWindow() {
        let recorder = LazyControllerEventRecorder()
        let window = NSWindow()
        let controller = LazyPreferencesWindowController {
            recorder.record("create-window")
            return RecordingPreferencesWindowController(window: window, recorder: recorder)
        }

        XCTAssertEqual(recorder.events, [])
        XCTAssertNil(controller.window)

        controller.showWindow(nil)

        XCTAssertEqual(recorder.events, [
            "create-window",
            "show-window"
        ])
        XCTAssertTrue(controller.window === window)
    }
}

@MainActor
private final class LazyControllerEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@MainActor
private final class RecordingDashboardPopoverController: DashboardPopoverControlling {
    private let recorder: LazyControllerEventRecorder

    init(recorder: LazyControllerEventRecorder) {
        self.recorder = recorder
    }

    func toggle(relativeTo view: NSView?) {
        recorder.record("toggle-popover")
    }
}

@MainActor
private final class RecordingPreferencesWindowController: PreferencesWindowControlling {
    let window: NSWindow?
    private let recorder: LazyControllerEventRecorder

    init(window: NSWindow?, recorder: LazyControllerEventRecorder) {
        self.window = window
        self.recorder = recorder
    }

    func showWindow(_ sender: Any?) {
        recorder.record("show-window")
    }
}
