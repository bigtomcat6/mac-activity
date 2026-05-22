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
            "activation:accessory",
        ])
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
