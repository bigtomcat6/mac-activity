import CoreAudio
import Combine
import MacActivityCore
import XCTest

@testable import MacActivityApp

@MainActor
final class AudioControlCoordinatorTests: XCTestCase {
    func testDefaultBrowsingStateStartsEmptyWithoutProcessTapState() {
        let snapshot: AudioControlSnapshot = .empty

        XCTAssertEqual(snapshot.devices, [])
        XCTAssertEqual(snapshot.processes, [])
    }

    func testUnsupportedStartupShowsDevicesWithoutEnumeratingProcessesOrApplying() async {
        let fixture = CoordinatorFixture(availability: .unsupported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.devices.map(\.id), ["BuiltIn"])
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testSupportedStartupCleansOrphansAndStartsMonitoring() async {
        let fixture = CoordinatorFixture(availability: .supported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.engine.cleanupCount, 1)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testSupportedDefaultBrowsingDoesNotApplyOrAttemptAuthorization() async {
        let fixture = CoordinatorFixture(availability: .supported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.authorizationAttemptCount, 0)
    }

    func testRapidDeviceSliderIntentsCoalesceAndRollbackWithoutProcessEnumeration() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(
            availability: .supported,
            delay: delay.callAsFunction
        )
        await fixture.coordinator.start()
        fixture.deviceProvider.volumeWriteError = FixtureError.writeFailed

        fixture.coordinator.setDeviceVolume(0.6, for: "BuiltIn")
        fixture.coordinator.setDeviceVolume(0.7, for: "BuiltIn")
        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.8)

        for _ in 0..<12 { await Task.yield() }
        let delayCallCount = await delay.callCount
        XCTAssertEqual(delayCallCount, 1)
        await delay.resumeAll()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [0.8])
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.5)
        XCTAssertEqual(fixture.processProvider.callCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].error, .deviceWrite)
    }

    func testBundlelessProcessIntentIsSessionOnly() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            bundleIdentifier: nil
        )
        await fixture.coordinator.start()

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.count, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.store.saveCount, 0)
    }

    func testExplicitRouteUsesExactlySelectedTargetsWithoutDefaultInjection() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: 11
        )
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
        XCTAssertFalse(fixture.engine.plans.last?.selectedTargetUIDs.contains("BuiltIn") ?? true)
    }

    func testSavedNonDefaultProfileRestoresButSavedDefaultDoesNotApply() async {
        let saved = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.35
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [saved.bundleIdentifier: saved]
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.count, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.35)

        let defaultProfile = AudioProcessProfile(bundleIdentifier: "com.example.music")
        let defaultFixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [defaultProfile.bundleIdentifier: defaultProfile]
        )
        await defaultFixture.coordinator.start()
        await defaultFixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(defaultFixture.engine.plans.count, 0)
    }

    func testPermissionFailureRetainsPendingRequestAndRetrySucceeds() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.nextError = .permissionDenied(-1)

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .permissionDenied)

        fixture.engine.nextError = nil
        fixture.coordinator.retry(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
    }

    func testResetStopsNonDefaultSessionWithoutApplyingDefaultProfile() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.plans.count, 1)

        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.count, 1)
        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 1)
        XCTAssertNil(fixture.store.savedPreferences.audioProcessProfiles["com.example.music"])
    }

    func testPersistenceFailureStopsNewSessionAndRollsBackVisibleState() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.store.saveError = FixtureError.writeFailed

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .persistenceFailed)
    }

    func testPersistenceFailureRestoresPreviousNonDefaultEngineRuleWithoutRepersistingIt() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveFailuresRemaining = 2

        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.gains.map(\.volume), [0.4, 0.6, 0.4])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.6)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .persistenceFailed)
    }

    func testSamePIDNewObjectStopsOldSessionAndPublishesNewIdentity() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.processProvider.processes = [.music(objectID: 22)]

        fixture.monitor.emit([.processList])
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [22])
    }

    func testEngineSnapshotsUseStrictLexicographicOrderAndIgnoreDuplicates() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        let newest = ProcessTapSessionSnapshot(
            processObjectID: 11,
            generation: 2,
            state: .running,
            error: nil,
            commandSequence: 2,
            emissionOrdinal: 2
        )
        fixture.engine.emit(newest)
        fixture.engine.emit(.init(
            processObjectID: 11,
            generation: 1,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: 1,
            emissionOrdinal: 9
        ))
        fixture.engine.emit(.init(
            processObjectID: 11,
            generation: 2,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: 2,
            emissionOrdinal: 1
        ))
        fixture.engine.emit(newest)

        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, newest)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testShutdownStopsMonitorBeforeAwaitedStopAll() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        await fixture.coordinator.shutdown()

        XCTAssertEqual(fixture.lifecycle.events.suffix(2), ["monitor.stop", "engine.stopAll"])
    }

    func testExplicitTargetDisconnectRebuildsWithRemainingTargetsWithoutRewritingSelection() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["BuiltIn", "USB"]),
            for: 11
        )
        await fixture.coordinator.testingWaitUntilIdle()

        fixture.deviceProvider.setAlive(false, uid: "USB")
        fixture.monitor.emit([.device(20, .liveness)])
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn"])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["BuiltIn", "USB"])
        )

        fixture.deviceProvider.setAlive(true, uid: "USB")
        fixture.monitor.emit([.device(20, .liveness)])
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn", "USB"])
    }

    func testUnavailableSavedExplicitRouteDoesNotApplyOrInjectDefaultAndRetriesOnReconnect() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.5,
            route: .explicit(targetDeviceUIDs: ["USB"])
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )
        fixture.deviceProvider.setAlive(false, uid: "USB")

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans, [])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .targetUnavailable(["USB"]))
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles[profile.bundleIdentifier]?.route,
            .explicit(targetDeviceUIDs: ["USB"])
        )

        fixture.deviceProvider.setAlive(true, uid: "USB")
        fixture.monitor.emit([.device(20, .liveness)])
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
    }

    func testLossOfAllExplicitTargetsStopsTapAndRetainsUnavailableRoute() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        fixture.deviceProvider.setAlive(false, uid: "USB")
        fixture.monitor.emit([.deviceList])
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["USB"])
        )
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .targetUnavailable(["USB"])
        )
    }

    func testSourceOutputChangeRebuildsFollowOriginalButDefaultChangeDoesNotRebuildExplicit() async {
        let followFixture = CoordinatorFixture(availability: .supported)
        await followFixture.coordinator.start()
        followFixture.coordinator.setProcessVolume(0.5, for: 11)
        await followFixture.coordinator.testingWaitUntilIdle()
        followFixture.processProvider.processes = [.music(objectID: 11, outputDeviceIDs: [20])]
        followFixture.monitor.emit([.process(11, .outputDevices)])
        await followFixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(followFixture.engine.plans.last?.selectedTargetUIDs, ["USB"])

        followFixture.processProvider.processes = [.music(objectID: 11, outputDeviceIDs: [10])]
        followFixture.monitor.emit([.defaultOutputDevice])
        await followFixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(followFixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn"])

        let explicitFixture = CoordinatorFixture(availability: .supported)
        await explicitFixture.coordinator.start()
        explicitFixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await explicitFixture.coordinator.testingWaitUntilIdle()
        let applyCount = explicitFixture.engine.plans.count
        explicitFixture.monitor.emit([.defaultOutputDevice])
        await explicitFixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(explicitFixture.engine.plans.count, applyCount)
        XCTAssertEqual(explicitFixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
    }

    func testSampleRateChangeRebuildsOnlySessionUsingDevice() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let applyCount = fixture.engine.plans.count

        fixture.monitor.emit([.device(10, .nominalSampleRate)])
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.plans.count, applyCount + 1)

        fixture.monitor.emit([.device(20, .nominalSampleRate)])
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.plans.count, applyCount + 1)
    }

    func testServiceRestartStopsRefreshesCleansAndRestores() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let initialApplyCount = fixture.engine.plans.count

        fixture.monitor.emit([.serviceRestarted])
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertTrue(fixture.lifecycle.events.contains("engine.stopAll"))
        XCTAssertEqual(fixture.engine.cleanupCount, 2)
        XCTAssertGreaterThan(fixture.engine.plans.count, initialApplyCount)
    }

    func testGenericEngineFailureIsTypedAndRetryable() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.nextError = .unsupportedFormat

        fixture.coordinator.setProcessMuted(true, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .operationFailed(.unsupportedFormat)
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.isMuted, true)
    }

    func testDeviceMuteUsesConfirmedValueAndRollsBackOnFailure() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.deviceProvider.confirmedMute = true
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)

        fixture.deviceProvider.muteWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceMuted(false, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].error, .deviceWrite)
    }

    func testDeviceVolumeUsesHardwareConfirmedValueAndRetryRefreshesOneRow() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.deviceProvider.confirmedVolume = 0.73
        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.73)

        fixture.deviceProvider.volumeWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceVolume(0.9, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.deviceProvider.snapshotVolume = 0.61
        fixture.coordinator.retryDevice("BuiltIn")
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.61)
        XCTAssertNil(fixture.coordinator.snapshot.devices[0].error)
        XCTAssertEqual(fixture.processProvider.callCount, 1)
    }

    func testShutdownCancelsPendingSliderWrite() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.coordinator.setDeviceVolume(0.9, for: "BuiltIn")

        await fixture.coordinator.shutdown()
        await delay.resumeAll()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [])
    }

    func testCoordinatorDeallocatesAfterPopoverObservationEnds() async {
        weak var weakCoordinator: AudioControlCoordinator?
        var fixture: CoordinatorFixture? = CoordinatorFixture(availability: .supported)
        await fixture?.coordinator.start()
        weakCoordinator = fixture?.coordinator
        var cancellable = fixture?.coordinator.snapshotPublisher.sink { _ in }

        cancellable = nil
        fixture = nil
        for _ in 0..<8 { await Task.yield() }

        XCTAssertNil(cancellable)
        XCTAssertNil(weakCoordinator)
    }
}

private enum FixtureError: Error {
    case writeFailed
}

@MainActor
private final class CoordinatorFixture {
    let deviceProvider = DeviceProviderFake()
    let processProvider = ProcessProviderFake()
    let monitor = MonitorFake()
    let engine = EngineFake()
    let store = PreferencesStoreFake()
    let lifecycle = LifecycleRecorder()
    let coordinator: AudioControlCoordinator

    init(
        availability: AudioFeatureAvailability,
        bundleIdentifier: String? = "com.example.music",
        savedProfiles: [String: AudioProcessProfile] = [:],
        delay: @escaping AudioControlDelay = { _ in }
    ) {
        processProvider.bundleIdentifier = bundleIdentifier
        store.savedPreferences.audioProcessProfiles = savedProfiles
        monitor.lifecycle = lifecycle
        engine.lifecycle = lifecycle
        let preferences = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )
        let planner = Self.validatedPlanner(devices: deviceProvider.routeDescriptors)
        coordinator = AudioControlCoordinator(
            availability: availability,
            deviceProvider: deviceProvider,
            processProvider: processProvider,
            routeDeviceProvider: deviceProvider,
            monitor: monitor,
            planner: planner,
            engine: engine,
            preferences: preferences,
            delay: delay
        )
    }

    private static func validatedPlanner(devices: [AudioRouteDevice]) -> AudioRoutePlanner {
        let fingerprintPlanner = AudioRoutePlanner()
        let requests: [([String], AudioRouteMode)] = [
            (["BuiltIn"], .followOriginal),
            (["USB"], .followOriginal),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["USB"])),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["BuiltIn", "USB"])),
        ]
        let fingerprints = requests.compactMap { sourceUIDs, mode in
            try? fingerprintPlanner.topologyFingerprint(for: .init(
                processObjectID: 11,
                generation: 1,
                sourceDeviceUIDs: sourceUIDs,
                systemDefaultOutputDeviceUID: nil,
                mode: mode,
                devices: devices
            ))
        }
        return AudioRoutePlanner(
            policy: .init(validatedFingerprints: Set(fingerprints))
        )
    }
}

private extension AudioFeatureAvailability {
    static let unsupported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0)
    )
    static let supported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0)
    )
}

@MainActor
private final class DeviceProviderFake: AudioDeviceControlProviding, AudioRouteDeviceProviding {
    var volumeWriteError: Error?
    var muteWriteError: Error?
    var confirmedMute = false
    var confirmedVolume = 0.5
    var snapshotVolume = 0.5
    private(set) var volumeWrites: [Double] = []

    var routeDescriptors: [AudioRouteDevice] = [
        makeRouteDevice(id: 10, uid: "BuiltIn"),
        makeRouteDevice(id: 20, uid: "USB"),
    ]

    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] {
        [.init(
            id: "BuiltIn",
            objectID: 10,
            name: "Speakers",
            volume: .value(snapshotVolume, isWritable: true),
            mute: .value(false, isWritable: true)
        )]
    }

    func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot {
        try outputDeviceSnapshots()[0]
    }

    func writeVolume(_ volume: Double, forUID uid: String) throws -> Double {
        volumeWrites.append(volume)
        if let volumeWriteError { throw volumeWriteError }
        return confirmedVolume
    }
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool {
        if let muteWriteError { throw muteWriteError }
        return confirmedMute
    }
    func routeDevices() throws -> [AudioRouteDevice] { routeDescriptors }

    func setAlive(_ isAlive: Bool, uid: String) {
        routeDescriptors = routeDescriptors.map { device in
            guard device.uid == uid else { return device }
            return AudioRouteDevice(
                objectID: device.objectID,
                uid: device.uid,
                name: device.name,
                isAlive: isAlive,
                isAggregate: device.isAggregate,
                aggregateSubdeviceUIDs: device.aggregateSubdeviceUIDs,
                inputStreams: device.inputStreams,
                outputStreams: device.outputStreams,
                clockDomain: device.clockDomain,
                transportType: device.transportType,
                modelUID: device.modelUID,
                driverIdentity: device.driverIdentity,
                aggregateComposition: device.aggregateComposition
            )
        }
    }

    private static func makeRouteDevice(id: AudioObjectID, uid: String) -> AudioRouteDevice {
        AudioRouteDevice(
            objectID: id,
            uid: uid,
            name: uid,
            isAlive: true,
            isAggregate: false,
            aggregateSubdeviceUIDs: [],
            outputStreams: [.init(
                streamObjectID: id * 100,
                streamIndex: 0,
                format: .init(
                    sampleRate: 48_000,
                    channelCount: 2,
                    formatID: kAudioFormatLinearPCM,
                    formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                    bitsPerChannel: 32,
                    interleaving: .interleaved
                )
            )],
            clockDomain: 100,
            transportType: kAudioDeviceTransportTypeBuiltIn,
            modelUID: "model.\(uid)",
            driverIdentity: .init(plugInBundleID: "driver.\(uid)", availableVersion: nil)
        )
    }
}

@MainActor
private final class ProcessProviderFake: AudioProcessProviding {
    private(set) var callCount = 0
    var bundleIdentifier: String? = "com.example.music"
    var processes: [AudioProcessEntry]?

    func audibleOutputProcesses() -> [AudioProcessEntry] {
        callCount += 1
        return processes ?? [.init(
            processObjectID: 11,
            processIdentifier: 101,
            name: "Music",
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            outputDeviceIDs: [10]
        )]
    }
}

private extension AudioProcessEntry {
    static func music(
        objectID: AudioObjectID,
        outputDeviceIDs: [AudioDeviceID] = [10]
    ) -> AudioProcessEntry {
        .init(
            processObjectID: objectID,
            processIdentifier: 101,
            name: "Music",
            bundleIdentifier: "com.example.music",
            bundleURL: nil,
            outputDeviceIDs: outputDeviceIDs
        )
    }
}

private final class MonitorFake: AudioSystemMonitoring, @unchecked Sendable {
    let changes: AsyncStream<Set<AudioSystemChange>>
    private let continuation: AsyncStream<Set<AudioSystemChange>>.Continuation
    var lifecycle: LifecycleRecorder?
    private(set) var startCount = 0
    private(set) var observedDeviceIDs: Set<AudioDeviceID> = []
    private(set) var observedProcessObjectIDs: Set<AudioObjectID> = []

    init() {
        let stream = AsyncStream<Set<AudioSystemChange>>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
    }

    func start() throws { startCount += 1 }
    func updateObservedObjects(
        deviceIDs: Set<AudioDeviceID>,
        processObjectIDs: Set<AudioObjectID>
    ) throws {
        observedDeviceIDs = deviceIDs
        observedProcessObjectIDs = processObjectIDs
    }
    func stop() { lifecycle?.events.append("monitor.stop") }
    func emit(_ changes: Set<AudioSystemChange>) { continuation.yield(changes) }
}

private final class EngineFake: ProcessTapVolumeControlling, @unchecked Sendable {
    let sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot>
    private let continuation: AsyncStream<ProcessTapSessionSnapshot>.Continuation
    private(set) var applyCount = 0
    private(set) var cleanupCount = 0
    private(set) var authorizationAttemptCount = 0
    private(set) var plans: [AudioRoutePlan] = []
    private(set) var gains: [ProcessGainState] = []
    private(set) var stoppedProcessObjectIDs: [AudioObjectID] = []
    var nextError: ProcessTapEngineError?
    var lifecycle: LifecycleRecorder?
    private var nextCommandSequence: UInt64 = 0

    init() {
        let stream = AsyncStream<ProcessTapSessionSnapshot>.makeStream()
        sessionSnapshots = stream.stream
        continuation = stream.continuation
    }

    func apply(plan: AudioRoutePlan, gain: ProcessGainState) async -> ProcessTapSessionSnapshot {
        applyCount += 1
        authorizationAttemptCount += 1
        plans.append(plan)
        gains.append(gain)
        nextCommandSequence += 1
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: plan.processObjectID,
            generation: plan.generation,
            state: nextError == nil ? .running : .failed,
            error: nextError,
            commandSequence: nextCommandSequence,
            emissionOrdinal: 1
        )
        continuation.yield(snapshot)
        return snapshot
    }
    func updateGain(_ gain: ProcessGainState, for processObjectID: AudioObjectID) async {}
    func stop(processObjectID: AudioObjectID, generation: UInt64) async -> ProcessTapSessionSnapshot {
        stoppedProcessObjectIDs.append(processObjectID)
        nextCommandSequence += 1
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: .idle,
            error: nil,
            commandSequence: nextCommandSequence,
            emissionOrdinal: 1
        )
        continuation.yield(snapshot)
        return snapshot
    }
    func stopAll() async { lifecycle?.events.append("engine.stopAll") }
    func cleanupOrphans() async -> [AudioTeardownFailure] {
        cleanupCount += 1
        return []
    }
    func emit(_ snapshot: ProcessTapSessionSnapshot) { continuation.yield(snapshot) }
}

private final class PreferencesStoreFake: PreferencesStoring, @unchecked Sendable {
    private(set) var saveCount = 0
    var savedPreferences: AppPreferences = .default
    var saveError: Error?
    var saveFailuresRemaining = 0
    func load() -> AppPreferences { savedPreferences }
    func save(_ preferences: AppPreferences) throws {
        saveCount += 1
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw FixtureError.writeFailed
        }
        if let saveError { throw saveError }
        savedPreferences = preferences
    }
}

private final class LifecycleRecorder: @unchecked Sendable {
    var events: [String] = []
}

private actor ControlledAudioDelay {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    func callAsFunction(_ duration: Duration) async {
        callCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
