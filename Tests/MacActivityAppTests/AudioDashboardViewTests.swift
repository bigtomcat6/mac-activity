import AppKit
import Combine
import CoreAudio
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioDashboardViewTests: XCTestCase {
    func testRealViewWiresContractsWithoutAnAccessibilityManifest() throws {
        let source = try audioDashboardViewSource()

        XCTAssertFalse(source.contains("var accessibilityContracts"))
        let requiredCalls: [(String, Int)] = [
            ("accessibility: presentation.devicesAccessibility", 1),
            ("accessibility: processSection.accessibility", 1),
            (".audioAccessibility(accessibility)", 2),
            (".audioAccessibility(processSection.emptyAccessibility)", 1),
            (".audioAccessibility(presentation.volumeAccessibility)", 6),
            (".audioAccessibility(presentation.muteAccessibility)", 5),
            (".audioAccessibility(presentation.rowAccessibility)", 2),
            (".audioAccessibility(presentation.resetAccessibility)", 1),
            (".audioAccessibility(presentation.routeAccessibility)", 1),
            (".audioAccessibility(presentation.statusAccessibility", 1),
            (".audioAccessibility(contract)", 1),
            (".audioAccessibility(retryAccessibility)", 2),
            (".audioAccessibility(writeFailureAccessibility)", 1),
            ("modifier(AudioAccessibilityModifier(contract: contract))", 1),
        ]
        for (call, count) in requiredCalls {
            XCTAssertEqual(source.components(separatedBy: call).count - 1, count, call)
        }
    }

    func testSwiftPMHostingAXProbeReturnsExplicitUnavailableEvidence() {
        let model = AudioDashboardModel(coordinator: AudioViewCoordinatorSpy(snapshot: .fixture()))
        let controller = NSHostingController(rootView: AudioDashboardView(model: model))
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()

        guard case .unavailable(let evidence) = hostingAXEvidence(for: controller.view) else {
            return XCTFail("SwiftPM unexpectedly exposed the audio accessibility contract")
        }
        XCTAssertEqual(evidence.typedChildren, 0)
        XCTAssertEqual(evidence.navigationChildren, 0)
        XCTAssertTrue(evidence.audioIdentifiers.isEmpty)
    }

    func testRouteMutationUsesExplicitRouteOrderAcrossConsecutiveToggles() throws {
        var route = AudioRouteMode.explicit(targetDeviceUIDs: ["Missing", "USB"])
        let options = [
            AudioRouteDeviceOption(uid: "USB", name: "USB", isAvailable: true, isSelected: true),
            AudioRouteDeviceOption(uid: "Missing", name: "Old", isAvailable: false, isSelected: true),
            AudioRouteDeviceOption(uid: "AirPlay", name: "AirPlay", isAvailable: true, isSelected: false)
        ]

        route = .explicit(targetDeviceUIDs: try XCTUnwrap(
            AudioDashboardRouteSelection.updating(
                route: route, options: options, uid: "AirPlay", selected: true
            )
        ))
        XCTAssertEqual(route, .explicit(targetDeviceUIDs: ["Missing", "USB", "AirPlay"]))
        XCTAssertEqual(
            AudioDashboardRouteSelection.updating(
                route: route, options: options, uid: "USB", selected: false
            ),
            ["Missing", "AirPlay"]
        )
    }

    func testNativeControlBindingsUseLatestStableTargetsAndExactRouteActions() {
        let coordinator = AudioViewCoordinatorSpy(snapshot: .fixture())
        let model = AudioDashboardModel(coordinator: coordinator)
        let deviceVolume = AudioDashboardControlBindings.deviceVolume(
            model: model, deviceUID: "BuiltInOutput", fallback: 0
        )
        let processVolume = AudioDashboardControlBindings.processVolume(
            model: model, processObjectID: 11, fallback: 0
        )
        let airPlay = AudioDashboardControlBindings.routeTarget(
            model: model, processObjectID: 11, deviceUID: "AirPlay"
        )

        coordinator.update { snapshot in
            snapshot.devices[0].device = .fixtureDevice(uid: "BuiltInOutput", volume: 0.23)
            snapshot.processes[0].volume = 0.41
            snapshot.processes[0].routeOptions.append(.init(
                uid: "AirPlay", name: "AirPlay", isAvailable: true, isSelected: false
            ))
        }
        XCTAssertEqual(deviceVolume.wrappedValue, 0.23)
        XCTAssertEqual(processVolume.wrappedValue, 0.41)

        deviceVolume.wrappedValue = 0.61
        processVolume.wrappedValue = 0.72
        AudioDashboardControlBindings.toggleDeviceMute(
            model: model, deviceUID: "BuiltInOutput"
        )
        AudioDashboardControlBindings.toggleProcessMute(
            model: model, processObjectID: 11
        )

        airPlay.wrappedValue = true
        AudioDashboardControlBindings.routeTarget(
            model: model, processObjectID: 11, deviceUID: "USB"
        ).wrappedValue = false
        XCTAssertEqual(coordinator.routes, [
            .explicit(targetDeviceUIDs: ["USB", "Missing", "AirPlay"]),
            .explicit(targetDeviceUIDs: ["Missing", "AirPlay"])
        ])
        XCTAssertEqual(coordinator.deviceVolumes.count, 1)
        XCTAssertEqual(coordinator.deviceVolumes[0].0, "BuiltInOutput")
        XCTAssertEqual(coordinator.deviceVolumes[0].1, 0.61)
        XCTAssertEqual(coordinator.processVolumes.count, 1)
        XCTAssertEqual(coordinator.processVolumes[0].0, 11)
        XCTAssertEqual(coordinator.processVolumes[0].1, 0.72)
        XCTAssertEqual(coordinator.deviceMutes.count, 1)
        XCTAssertEqual(coordinator.deviceMutes[0].0, "BuiltInOutput")
        XCTAssertTrue(coordinator.deviceMutes[0].1)
        XCTAssertEqual(coordinator.processMutes.count, 1)
        XCTAssertEqual(coordinator.processMutes[0].0, 11)
        XCTAssertTrue(coordinator.processMutes[0].1)
    }

    func testMuteFailurePresentationsContainVisibleDeviceNameTextAndRetry() {
        for mute in [AudioPropertyValue<Bool>.unavailable, .failed(Self.halFailure)] {
            let row = AudioDeviceRowPresentation(.fixture(mute: mute))
            XCTAssertTrue(row.muteAccessibility.label?.contains("BuiltInOutput") == true)
            XCTAssertNotNil(row.retryAccessibility)
        }
    }

    func testEveryEngineTransitionHasDistinctTruthfulPresentation() {
        let expected: [(ProcessTapSessionState, AudioProcessStatusPresentation)] = [
            (.preparing, .preparing),
            (.rebuilding, .rebuilding),
            (.running, .running),
            (.stopping, .stopping)
        ]
        let rows = expected.map { state, _ -> AudioProcessRowPresentation in
            var process = AudioProcessControlSnapshot.fixture()
            process.session = .fixture(state: state)
            return AudioProcessRowPresentation(process)
        }

        XCTAssertEqual(rows.map(\.status), expected.map(\.1))
        XCTAssertEqual(Set(rows.compactMap { $0.statusAccessibility?.label }).count, 4)
    }

    func testAccessibilityContractsDriveTargetLabelsValuesAndEnabledState() throws {
        let device = AudioDeviceRowPresentation(.fixture())
        XCTAssertEqual(device.volumeAccessibility.identifier,
                       "audio.device.BuiltInOutput.volume.slider")
        XCTAssertTrue(device.volumeAccessibility.label?.contains("BuiltInOutput") == true)
        XCTAssertEqual(device.volumeAccessibility.value, "50%")

        let process = AudioProcessRowPresentation(.fixture())
        let unavailable = try XCTUnwrap(process.snapshot.routeOptions.last)
        let unavailableContract = process.routeTargetAccessibility(unavailable)
        XCTAssertTrue(unavailableContract.label?.contains(unavailable.name) == true)
        XCTAssertFalse(unavailableContract.label?.contains("Selected") == true)
        XCTAssertNil(unavailableContract.value, "Native Toggle owns selected-state semantics")
        XCTAssertTrue(unavailableContract.isEnabled)
    }

    func testExplicitLowVersionMatrixHidesProcessContractsWithoutApplyingAudio() throws {
        for version in [(13, 0), (14, 0), (14, 1)] {
            let availability = AudioFeatureAvailability(operatingSystemVersion: .init(
                majorVersion: version.0, minorVersion: version.1, patchVersion: 0
            ))
            let coordinator = AudioViewCoordinatorSpy(
                supportsProcessControls: availability.supportsProcessControls,
                snapshot: .fixture()
            )
            let presentation = AudioDashboardPresentation(
                snapshot: coordinator.snapshot,
                supportsProcessControls: coordinator.supportsProcessControls
            )

            XCTAssertEqual(presentation.devicesAccessibility.identifier, "audio.devices.section")
            XCTAssertNil(presentation.processSection)
            XCTAssertEqual(coordinator.intentCount, 0)
        }
    }

    func testSupportedEmptyStateCreatesNoApplyIntent() throws {
        let coordinator = AudioViewCoordinatorSpy(
            supportsProcessControls: true,
            snapshot: AudioControlSnapshot(devices: [.fixture()], processes: [])
        )
        let presentation = AudioDashboardPresentation(
            snapshot: coordinator.snapshot,
            supportsProcessControls: coordinator.supportsProcessControls
        )
        let section = try XCTUnwrap(presentation.processSection)

        XCTAssertEqual(section.accessibility.identifier, "audio.processes.section")
        XCTAssertEqual(section.emptyAccessibility.identifier, "audio.processes.empty")
        XCTAssertEqual(coordinator.intentCount, 0)
    }

    func testUnavailableAndFailedDevicesRemainVisibleWithRetryAndNoSlider() {
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
        let rows = snapshot.devices.map(AudioDeviceRowPresentation.init)

        XCTAssertEqual(rows[0].volumeAccessibility.identifier,
                       "audio.device.missing.volume.unavailable")
        XCTAssertEqual(rows[0].retryAccessibility?.identifier, "audio.device.missing.retry")
        XCTAssertEqual(rows[1].volumeAccessibility.identifier,
                       "audio.device.failed.volume.failed")
        XCTAssertEqual(rows[1].retryAccessibility?.identifier, "audio.device.failed.retry")
    }

    func testExplicitRouteMutationPreservesOrderAndUnavailableSelection() {
        let options = [
            AudioRouteDeviceOption(uid: "USB", name: "USB", isAvailable: true, isSelected: true),
            AudioRouteDeviceOption(uid: "Missing", name: "Old display", isAvailable: false, isSelected: true),
            AudioRouteDeviceOption(uid: "AirPlay", name: "AirPlay", isAvailable: true, isSelected: false)
        ]

        XCTAssertEqual(
            AudioDashboardRouteSelection.updating(
                route: .explicit(targetDeviceUIDs: ["USB", "Missing"]),
                options: options, uid: "AirPlay", selected: true
            ),
            ["USB", "Missing", "AirPlay"]
        )
        XCTAssertEqual(
            AudioDashboardRouteSelection.updating(
                route: .explicit(targetDeviceUIDs: ["USB", "Missing"]),
                options: options, uid: "USB", selected: false
            ),
            ["Missing"]
        )
        XCTAssertNil(
            AudioDashboardRouteSelection.updating(
                route: .explicit(targetDeviceUIDs: ["USB"]), options: [options[0]],
                uid: "USB",
                selected: false
            )
        )
    }

    func testControlsExposeTargetSpecificAccessibilityContracts() {
        let device = AudioDeviceRowPresentation(.fixture())
        let process = AudioProcessRowPresentation(.fixture())

        XCTAssertEqual(device.volumeAccessibility.identifier,
                       "audio.device.BuiltInOutput.volume.slider")
        XCTAssertEqual(device.muteAccessibility.identifier, "audio.device.BuiltInOutput.mute")
        XCTAssertEqual(process.volumeAccessibility.identifier, "audio.process.11.volume.slider")
        XCTAssertEqual(process.muteAccessibility.identifier, "audio.process.11.mute")
        XCTAssertEqual(process.routeAccessibility.identifier, "audio.process.11.route")
        XCTAssertEqual(process.resetAccessibility.identifier, "audio.process.11.reset")
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
        XCTAssertEqual(readOnly.volumeAccessibility.identifier,
                       "audio.device.readonly.volume.readOnly")
        XCTAssertEqual(unsupported.volume, .unsupported)
        XCTAssertEqual(unsupported.volumeAccessibility.identifier,
                       "audio.device.unsupported.volume.unsupported")
        XCTAssertNil(unsupported.retryAccessibility)
        XCTAssertEqual(readOnly.volumeAccessibility.value, "42%")
        XCTAssertEqual(unsupported.volumeAccessibility.identifier,
                       "audio.device.unsupported.volume.unsupported")
    }

    func testDeviceReadWriteAndMuteRecoveryContractsKeepTruthfulControlsAndRetry() {
        let writeFailure = AudioDeviceRowPresentation(AudioDeviceControlSnapshot(
            device: .fixtureDevice(uid: "Studio", volume: 0.34),
            error: .deviceWrite
        ))
        XCTAssertEqual(writeFailure.volume, .slider(0.34))
        XCTAssertEqual(writeFailure.writeFailureAccessibility?.identifier,
                       "audio.device.Studio.writeFailed")
        XCTAssertNotNil(writeFailure.retryAccessibility)

        for mute in [AudioPropertyValue<Bool>.unavailable, .failed(Self.halFailure)] {
            let row = AudioDeviceRowPresentation(.fixture(uid: "Studio", mute: mute))
            XCTAssertTrue(row.muteAccessibility.label?.contains("Studio") == true)
            XCTAssertNotNil(row.muteAccessibility.value)
            XCTAssertNotNil(row.retryAccessibility)
        }

        let readOnlyMute = AudioDeviceRowPresentation(.fixture(
            uid: "ReadOnly", mute: .value(true, isWritable: false)
        ))
        XCTAssertEqual(readOnlyMute.muteAccessibility.value,
                       AppLocalization.string(.audioMuted))
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
        XCTAssertEqual(reconstructed.status, .running)
    }

    func testProcessPreparingAndTypedErrorsExposeRetryAndReset() {
        var preparing = AudioProcessControlSnapshot.fixture()
        preparing.session = .fixture(state: .rebuilding)
        XCTAssertEqual(AudioProcessRowPresentation(preparing).status, .rebuilding)

        for error in [
            AudioControlUserError.permissionDenied,
            .targetUnavailable(["Missing"]),
            .operationFailed(.operationFailed(operation: .createTap, status: -1))
        ] {
            var failed = AudioProcessControlSnapshot.fixture()
            failed.error = error
            let row = AudioProcessRowPresentation(failed)
            XCTAssertEqual(row.status, .failed(error))
            XCTAssertNotNil(row.retryAccessibility)
            XCTAssertEqual(row.resetAccessibility.identifier, "audio.process.11.reset")
            XCTAssertNotNil(row.statusAccessibility?.label)
        }
        let errorLabels = [
            AudioControlUserError.permissionDenied,
            .targetUnavailable(["Missing"]),
            .operationFailed(.operationFailed(operation: .createTap, status: -1))
        ].map { error -> String? in
            var failed = AudioProcessControlSnapshot.fixture()
            failed.error = error
            return AudioProcessRowPresentation(failed).statusAccessibility?.label
        }
        XCTAssertEqual(Set(errorLabels.compactMap { $0 }).count, 3)
    }

    func testLastExplicitRouteTargetIsDisabledButFollowOriginalCanClearIt() {
        var process = AudioProcessControlSnapshot.fixture()
        process.route = .explicit(targetDeviceUIDs: ["Missing"])
        process.routeOptions = [
            .init(uid: "Missing", name: "Old Display", isAvailable: false, isSelected: true)
        ]
        let row = AudioProcessRowPresentation(process)
        let contract = row.routeTargetAccessibility(process.routeOptions[0])

        XCTAssertFalse(contract.isEnabled)
        XCTAssertTrue(contract.label?.contains("Old Display") == true)
        XCTAssertNil(AudioDashboardRouteSelection.updating(
            route: process.route,
            options: process.routeOptions,
            uid: "Missing",
            selected: false
        ))
    }

    private func audioDashboardViewSource() throws -> String {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MacActivityApp/Views/AudioDashboardView.swift"
            ),
            encoding: .utf8
        )
    }

    private func hostingAXEvidence(for view: NSView) -> HostingAXEvidence {
        let typedChildren = view.accessibilityChildren() ?? []
        let navigationChildren = view.accessibilityChildrenInNavigationOrder() ?? []
        let legacyChildren = view.accessibilityAttributeValue(.children) as? [Any] ?? []
        let unignoredElements = NSAccessibility.unignoredChildren(from: [view])
        let candidates = typedChildren + navigationChildren + legacyChildren
            + unignoredElements + view.subviews
        let audioIdentifiers = candidates.compactMap { candidate -> String? in
            (candidate as? NSAccessibilityProtocol)?.accessibilityIdentifier()
        }.filter { $0.hasPrefix("audio.") }
        let counts = HostingAXCounts(
            typedChildren: typedChildren.count,
            navigationChildren: navigationChildren.count,
            legacyChildren: legacyChildren.count,
            unignoredElements: unignoredElements.count,
            subviews: view.subviews.count,
            audioIdentifiers: audioIdentifiers
        )
        if audioIdentifiers.isEmpty {
            return .unavailable(counts)
        }
        return .available(counts)
    }

}

private struct HostingAXCounts: Equatable {
    let typedChildren: Int
    let navigationChildren: Int
    let legacyChildren: Int
    let unignoredElements: Int
    let subviews: Int
    let audioIdentifiers: [String]
}

private enum HostingAXEvidence: Equatable {
    case available(HostingAXCounts)
    case unavailable(HostingAXCounts)
}

private extension AudioControlSnapshot {
    static func fixture() -> Self {
        Self(
            devices: [.fixture()],
            processes: [.fixture()]
        )
    }
}

@MainActor
private final class AudioViewCoordinatorSpy: AudioControlCoordinating {
    let supportsProcessControls: Bool
    private(set) var snapshot: AudioControlSnapshot
    private let subject: CurrentValueSubject<AudioControlSnapshot, Never>
    var snapshotPublisher: AnyPublisher<AudioControlSnapshot, Never> { subject.eraseToAnyPublisher() }
    private(set) var routes: [AudioRouteMode] = []
    private(set) var deviceVolumes: [(String, Double)] = []
    private(set) var processVolumes: [(AudioObjectID, Double)] = []
    private(set) var deviceMutes: [(String, Bool)] = []
    private(set) var processMutes: [(AudioObjectID, Bool)] = []
    private(set) var intentCount = 0

    init(supportsProcessControls: Bool = true, snapshot: AudioControlSnapshot) {
        self.supportsProcessControls = supportsProcessControls
        self.snapshot = snapshot
        subject = CurrentValueSubject(snapshot)
    }

    func update(_ body: (inout AudioControlSnapshot) -> Void) {
        body(&snapshot)
        subject.send(snapshot)
    }

    func start() async {}
    func retryDevice(_ deviceUID: String) { intentCount += 1 }
    func setDeviceVolume(_ volume: Double, for deviceUID: String) {
        deviceVolumes.append((deviceUID, volume)); intentCount += 1
    }
    func setDeviceMuted(_ isMuted: Bool, for deviceUID: String) {
        deviceMutes.append((deviceUID, isMuted)); intentCount += 1
    }
    func setProcessVolume(_ volume: Double, for processObjectID: AudioObjectID) {
        processVolumes.append((processObjectID, volume)); intentCount += 1
    }
    func setProcessMuted(_ isMuted: Bool, for processObjectID: AudioObjectID) {
        processMutes.append((processObjectID, isMuted)); intentCount += 1
    }
    func setProcessRoute(_ route: AudioRouteMode, for processObjectID: AudioObjectID) {
        routes.append(route)
        intentCount += 1
        update { snapshot in
            guard let index = snapshot.processes.firstIndex(where: { $0.id == processObjectID }) else { return }
            snapshot.processes[index].route = route
            let selected = Set(route.targetDeviceUIDs)
            snapshot.processes[index].routeOptions = snapshot.processes[index].routeOptions.map {
                .init(uid: $0.uid, name: $0.name, isAvailable: $0.isAvailable,
                      isSelected: selected.contains($0.uid))
            }
        }
    }
    func retry(processObjectID: AudioObjectID) { intentCount += 1 }
    func reset(processObjectID: AudioObjectID) { intentCount += 1 }
    func shutdown() async {}
}

private extension AudioDeviceControlSnapshot {
    static func fixture(
        uid: String = "BuiltInOutput",
        volume: AudioPropertyValue<Double> = .value(0.5, isWritable: true),
        mute: AudioPropertyValue<Bool> = .value(false, isWritable: true)
    ) -> Self {
        Self(
            device: AudioOutputDeviceSnapshot(
                id: uid,
                objectID: 1,
                name: uid,
                volume: volume,
                mute: mute
            ),
            error: nil
        )
    }
}

private extension AudioOutputDeviceSnapshot {
    static func fixtureDevice(uid: String, volume: Double) -> Self {
        Self(id: uid, objectID: 1, name: uid,
             volume: .value(volume, isWritable: true), mute: .value(false, isWritable: true))
    }
}

private extension AudioRouteMode {
    var targetDeviceUIDs: [String] {
        guard case .explicit(let targetDeviceUIDs) = self else { return [] }
        return targetDeviceUIDs
    }
}

private extension AudioDashboardViewTests {
    static var halFailure: AudioHALError {
        AudioHALError(operation: .getData, objectID: 1, address: nil, reason: .status(-1))
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
