import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioDashboardViewTests: XCTestCase {
    func testUnsupportedSystemOmitsEntireProcessFeature() throws {
        let tree = try render(snapshot: .fixture(), supportsProcessControls: false)

        XCTAssertTrue(tree.contains("audio.devices.section"))
        XCTAssertFalse(tree.contains("audio.processes.section"))
        XCTAssertFalse(tree.contains { $0.hasPrefix("audio.process.") })
    }

    func testUnavailableAndFailedDevicesRemainVisibleWithRetryAndNoSlider() throws {
        let snapshot = AudioControlSnapshot(
            devices: [
                .fixture(uid: "missing", volume: .unavailable),
                .fixture(uid: "failed", volume: .failed(AudioHALError(
                    operation: .getData,
                    objectID: 1,
                    address: nil,
                    reason: .status(-1)
                )))
            ],
            processes: []
        )
        let tree = try render(snapshot: snapshot, supportsProcessControls: true)

        XCTAssertTrue(tree.contains("audio.device.missing.volume.unavailable"))
        XCTAssertTrue(tree.contains("audio.device.missing.retry"))
        XCTAssertFalse(tree.contains("audio.device.missing.volume.slider"))
        XCTAssertTrue(tree.contains("audio.device.failed.volume.failed"))
        XCTAssertTrue(tree.contains("audio.device.failed.retry"))
    }

    func testExplicitRouteMutationPreservesOrderAndUnavailableSelection() {
        let options = [
            AudioRouteDeviceOption(uid: "USB", name: "USB", isAvailable: true, isSelected: true),
            AudioRouteDeviceOption(uid: "Missing", name: "Old display", isAvailable: false, isSelected: true),
            AudioRouteDeviceOption(uid: "AirPlay", name: "AirPlay", isAvailable: true, isSelected: false)
        ]

        XCTAssertEqual(
            AudioDashboardRouteSelection.updating(options: options, uid: "AirPlay", selected: true),
            ["USB", "Missing", "AirPlay"]
        )
        XCTAssertEqual(
            AudioDashboardRouteSelection.updating(options: options, uid: "USB", selected: false),
            ["Missing"]
        )
        XCTAssertNil(
            AudioDashboardRouteSelection.updating(
                options: [options[0]],
                uid: "USB",
                selected: false
            )
        )
    }

    func testControlsExposeTargetSpecificAccessibilityNamesAndActions() throws {
        let tree = try render(snapshot: .fixture(), supportsProcessControls: true)

        XCTAssertTrue(tree.contains("audio.device.BuiltInOutput.volume.slider"))
        XCTAssertTrue(tree.contains("audio.device.BuiltInOutput.mute"))
        XCTAssertTrue(tree.contains("audio.process.11.volume.slider"))
        XCTAssertTrue(tree.contains("audio.process.11.mute"))
        XCTAssertTrue(tree.contains("audio.process.11.route"))
        XCTAssertTrue(tree.contains("audio.process.11.reset"))
    }

    func testSupportedEmptyStateRendersProcessSectionWithoutRows() throws {
        let tree = try render(
            snapshot: AudioControlSnapshot(devices: [.fixture()], processes: []),
            supportsProcessControls: true
        )

        XCTAssertTrue(tree.contains("audio.processes.section"))
        XCTAssertTrue(tree.contains("audio.processes.empty"))
        XCTAssertFalse(tree.contains { $0.hasPrefix("audio.process.") })
    }

    func testDevicePresentationDoesNotFabricateUnsupportedOrReadOnlyValues() {
        let readOnly = AudioDeviceRowPresentation(.fixture(
            uid: "readonly",
            volume: .value(0.42, isWritable: false)
        ))
        let unsupported = AudioDeviceRowPresentation(.fixture(
            uid: "unsupported",
            volume: .unsupported
        ))

        XCTAssertEqual(readOnly.volume, .readOnly(0.42))
        XCTAssertFalse(readOnly.accessibilityIdentifiers.contains("audio.device.readonly.volume.slider"))
        XCTAssertEqual(unsupported.volume, .unsupported)
        XCTAssertFalse(unsupported.accessibilityIdentifiers.contains("audio.device.unsupported.volume.slider"))
        XCTAssertFalse(unsupported.showsRetry)
    }

    func testPendingAndReconstructedProcessRowsUseCoordinatorTruth() {
        var process = AudioProcessControlSnapshot.fixture()
        process.volume = 0.35
        process.isMuted = true
        process.pendingValues = AudioProcessControlValues(
            volume: 0.9,
            isMuted: false,
            route: .followOriginal
        )
        let first = AudioProcessRowPresentation(process)
        let reconstructed = AudioProcessRowPresentation(process)

        XCTAssertEqual(first.snapshot.volume, 0.35)
        XCTAssertTrue(first.snapshot.isMuted)
        XCTAssertEqual(reconstructed.snapshot.volume, first.snapshot.volume)
        XCTAssertEqual(reconstructed.snapshot.route, first.snapshot.route)
        XCTAssertEqual(reconstructed.status, .active)
    }

    func testProcessPreparingAndTypedErrorsExposeRetryAndReset() {
        var preparing = AudioProcessControlSnapshot.fixture()
        preparing.session = .fixture(state: .rebuilding)
        XCTAssertEqual(AudioProcessRowPresentation(preparing).status, .preparing)

        for error in [
            AudioControlUserError.permissionDenied,
            .targetUnavailable(["Missing"]),
            .operationFailed(.operationFailed(operation: .createTap, status: -1))
        ] {
            var failed = AudioProcessControlSnapshot.fixture()
            failed.error = error
            let row = AudioProcessRowPresentation(failed)
            XCTAssertEqual(row.status, .failed(error))
            XCTAssertTrue(row.accessibilityIdentifiers.contains("audio.process.11.retry"))
            XCTAssertTrue(row.accessibilityIdentifiers.contains("audio.process.11.reset"))
        }
    }

    private func render(
        snapshot: AudioControlSnapshot,
        supportsProcessControls: Bool
    ) throws -> [String] {
        let model = AudioDashboardModel(coordinator: TestAudioControlCoordinator(
            supportsProcessControls: supportsProcessControls,
            snapshot: snapshot
        ))
        let controller = NSHostingController(rootView: AudioDashboardView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        return Array(AudioDashboardPresentation(
            snapshot: snapshot,
            supportsProcessControls: supportsProcessControls
        ).accessibilityIdentifiers)
    }
}

private extension AudioControlSnapshot {
    static func fixture() -> Self {
        Self(
            devices: [.fixture()],
            processes: [.fixture()]
        )
    }
}

private extension AudioDeviceControlSnapshot {
    static func fixture(
        uid: String = "BuiltInOutput",
        volume: AudioPropertyValue<Double> = .value(0.5, isWritable: true)
    ) -> Self {
        Self(
            device: AudioOutputDeviceSnapshot(
                id: uid,
                objectID: 1,
                name: uid,
                volume: volume,
                mute: .value(false, isWritable: true)
            ),
            error: nil
        )
    }
}

private extension AudioProcessControlSnapshot {
    static func fixture() -> Self {
        Self(
            process: AudioProcessEntry(
                processObjectID: 11,
                processIdentifier: 101,
                name: "Music",
                bundleIdentifier: "com.apple.Music",
                bundleURL: nil
            ),
            volume: 0.7,
            isMuted: false,
            route: .explicit(targetDeviceUIDs: ["USB", "Missing"]),
            pendingValues: nil,
            routeOptions: [
                AudioRouteDeviceOption(uid: "USB", name: "USB", isAvailable: true, isSelected: true),
                AudioRouteDeviceOption(uid: "Missing", name: "Display", isAvailable: false, isSelected: true)
            ],
            session: ProcessTapSessionSnapshot(
                processObjectID: 11,
                generation: 1,
                state: .running,
                error: nil,
                commandSequence: 1,
                emissionOrdinal: 0
            ),
            error: nil
        )
    }
}

private extension ProcessTapSessionSnapshot {
    static func fixture(state: ProcessTapSessionState) -> Self {
        Self(
            processObjectID: 11,
            generation: 1,
            state: state,
            error: nil,
            commandSequence: 1,
            emissionOrdinal: 0
        )
    }
}
