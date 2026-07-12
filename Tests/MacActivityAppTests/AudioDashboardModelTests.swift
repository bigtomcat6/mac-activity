import Combine
import CoreAudio
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioDashboardModelTests: XCTestCase {
    func testInitialStateEqualsCoordinatorSnapshotAndPublisherReplacesIt() {
        let initial = Self.snapshot(deviceVolume: 0.4, processVolume: 0.7)
        let replacement = Self.snapshot(deviceVolume: 0.8, processVolume: 0.2)
        let coordinator = AudioControlCoordinatorSpy(snapshot: initial)
        let model = AudioDashboardModel(coordinator: coordinator)

        XCTAssertEqual(model.snapshot, initial)
        XCTAssertEqual(model.supportsProcessControls, coordinator.supportsProcessControls)

        coordinator.publish(replacement)

        XCTAssertEqual(model.snapshot, replacement)
    }

    func testEveryIntentForwardsStableDeviceUIDAndProcessObjectID() {
        let coordinator = AudioControlCoordinatorSpy(snapshot: Self.snapshot())
        let model = AudioDashboardModel(coordinator: coordinator)

        model.retryDevice("BuiltInOutput")
        model.setDeviceVolume(0.3, for: "BuiltInOutput")
        model.setDeviceMuted(true, for: "BuiltInOutput")
        let processObjectID = AudioObjectID(11)
        model.setProcessVolume(0.4, for: processObjectID)
        model.setProcessMuted(true, for: processObjectID)
        model.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: processObjectID)
        model.retry(processObjectID: 11)
        model.reset(processObjectID: 11)

        XCTAssertEqual(coordinator.intents, [
            .retryDevice("BuiltInOutput"),
            .deviceVolume(0.3, "BuiltInOutput"),
            .deviceMuted(true, "BuiltInOutput"),
            .processVolume(0.4, 11),
            .processMuted(true, 11),
            .processRoute(.explicit(targetDeviceUIDs: ["USB"]), 11),
            .retryProcess(11),
            .resetProcess(11)
        ])
    }

    func testUnsupportedCoordinatorKeepsDeviceControlsButHidesProcessControls() {
        let coordinator = AudioControlCoordinatorSpy(
            supportsProcessControls: false,
            snapshot: Self.snapshot()
        )
        let model = AudioDashboardModel(coordinator: coordinator)

        XCTAssertEqual(model.snapshot.devices.count, 1)
        XCTAssertEqual(model.snapshot.processes.count, 1)
        XCTAssertFalse(model.supportsProcessControls)
    }

    func testModelDeallocationDoesNotShutdownCoordinator() {
        let coordinator = AudioControlCoordinatorSpy(snapshot: Self.snapshot())
        weak var releasedModel: AudioDashboardModel?

        autoreleasepool {
            let model = AudioDashboardModel(coordinator: coordinator)
            releasedModel = model
            withExtendedLifetime(model) {}
        }

        XCTAssertNil(releasedModel)
        XCTAssertEqual(coordinator.shutdownCallCount, 0)
    }

    private static func snapshot(
        deviceVolume: Double = 0.4,
        processVolume: Double = 0.7
    ) -> AudioControlSnapshot {
        AudioControlSnapshot(
            devices: [
                AudioDeviceControlSnapshot(
                    device: AudioOutputDeviceSnapshot(
                        id: "BuiltInOutput",
                        objectID: 1,
                        name: "MacBook Speakers",
                        volume: .value(deviceVolume, isWritable: true),
                        mute: .value(false, isWritable: true)
                    ),
                    error: nil
                )
            ],
            processes: [
                AudioProcessControlSnapshot(
                    process: AudioProcessEntry(
                        processObjectID: 11,
                        processIdentifier: 101,
                        name: "Music",
                        bundleIdentifier: "com.apple.Music",
                        bundleURL: nil
                    ),
                    volume: processVolume,
                    isMuted: false,
                    route: .followOriginal,
                    pendingValues: nil,
                    routeOptions: [],
                    session: ProcessTapSessionSnapshot(
                        processObjectID: 11,
                        generation: 0,
                        state: .idle,
                        error: nil,
                        commandSequence: 0,
                        emissionOrdinal: 0
                    ),
                    error: nil
                )
            ]
        )
    }
}

@MainActor
private final class AudioControlCoordinatorSpy: AudioControlCoordinating {
    enum Intent: Equatable {
        case retryDevice(String)
        case deviceVolume(Double, String)
        case deviceMuted(Bool, String)
        case processVolume(Double, AudioObjectID)
        case processMuted(Bool, AudioObjectID)
        case processRoute(AudioRouteMode, AudioObjectID)
        case retryProcess(AudioObjectID)
        case resetProcess(AudioObjectID)
    }

    let supportsProcessControls: Bool
    private(set) var snapshot: AudioControlSnapshot
    private let subject: CurrentValueSubject<AudioControlSnapshot, Never>
    var snapshotPublisher: AnyPublisher<AudioControlSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }
    private(set) var intents: [Intent] = []
    private(set) var shutdownCallCount = 0

    init(supportsProcessControls: Bool = true, snapshot: AudioControlSnapshot) {
        self.supportsProcessControls = supportsProcessControls
        self.snapshot = snapshot
        self.subject = CurrentValueSubject(snapshot)
    }

    func publish(_ snapshot: AudioControlSnapshot) {
        self.snapshot = snapshot
        subject.send(snapshot)
    }

    func start() async {}
    func retryDevice(_ deviceUID: String) { intents.append(.retryDevice(deviceUID)) }
    func setDeviceVolume(_ volume: Double, for deviceUID: String) {
        intents.append(.deviceVolume(volume, deviceUID))
    }
    func setDeviceMuted(_ isMuted: Bool, for deviceUID: String) {
        intents.append(.deviceMuted(isMuted, deviceUID))
    }
    func setProcessVolume(_ volume: Double, for processObjectID: AudioObjectID) {
        intents.append(.processVolume(volume, processObjectID))
    }
    func setProcessMuted(_ isMuted: Bool, for processObjectID: AudioObjectID) {
        intents.append(.processMuted(isMuted, processObjectID))
    }
    func setProcessRoute(_ route: AudioRouteMode, for processObjectID: AudioObjectID) {
        intents.append(.processRoute(route, processObjectID))
    }
    func retry(processObjectID: AudioObjectID) { intents.append(.retryProcess(processObjectID)) }
    func reset(processObjectID: AudioObjectID) { intents.append(.resetProcess(processObjectID)) }
    func shutdown() async { shutdownCallCount += 1 }
}
