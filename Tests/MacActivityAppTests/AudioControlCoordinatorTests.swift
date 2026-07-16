import CoreAudio
import Combine
import XCTest

@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioControlCoordinatorTests: XCTestCase {
    func testDefaultBrowsingStateStartsEmptyWithoutProcessTapState() {
        let snapshot: AudioControlSnapshot = .empty

        XCTAssertEqual(snapshot.devices, [])
        XCTAssertEqual(snapshot.processes, [])
    }

    func testRouteDeviceOptionUsesUIDForStableIdentifier() {
        let option = AudioRouteDeviceOption(
            uid: "BuiltIn",
            name: "Built In Output",
            isAvailable: true,
            isSelected: false
        )

        XCTAssertEqual(option.id, "BuiltIn")
    }

    func testUnsupportedStartupShowsDevicesWithoutEnumeratingProcessesOrApplying() async {
        let fixture = CoordinatorFixture(availability: .unsupported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.devices.map(\.id), ["BuiltIn"])
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
        XCTAssertNil(fixture.coordinator.snapshot.processRuntimeError)
        XCTAssertFalse(fixture.lifecycle.events.contains("routes.read"))
    }

    func testConservativePolicyOnCapableOSSkipsAllProcessRuntimeWork() async {
        let availability = AudioFeatureAvailability(
            operatingSystemVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0),
            nativeValidationPolicy: .conservative
        )
        let fixture = CoordinatorFixture(availability: availability)

        await fixture.coordinator.start()

        XCTAssertFalse(fixture.coordinator.supportsProcessControls)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertFalse(fixture.lifecycle.events.contains("routes.read"))
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [])
    }

    func testNativeValidationRequiredRemainsDistinctCoordinatorError() {
        let fingerprint = AudioRouteTopologyFingerprint(
            osBuild: "test",
            sourceDeviceUIDs: ["source"],
            selectedTargetUIDs: ["target"],
            devices: []
        )

        XCTAssertEqual(
            AudioControlCoordinator.planningUserError(.nativeValidationRequired(fingerprint)),
            .routePlanning(.nativeValidationRequired(fingerprint))
        )
    }

    func testSupportedStartupCleansOrphansAndStartsMonitoring() async {
        let fixture = CoordinatorFixture(availability: .supported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testDefaultDelaySafelyClampsNonFiniteDeviceVolume() async {
        let deviceProvider = DeviceProviderFake()
        let processProvider = ProcessProviderFake()
        let monitor = MonitorFake()
        let engine = EngineFake()
        let preferences = PreferencesController(
            store: PreferencesStoreFake(),
            launchService: NoopLaunchAtLoginService()
        )
        let coordinator = AudioControlCoordinator(
            availability: .unsupported,
            deviceProvider: deviceProvider,
            processProvider: processProvider,
            routeDeviceProvider: deviceProvider,
            monitor: monitor,
            engine: engine,
            preferences: preferences
        )

        await coordinator.start()
        coordinator.setDeviceVolume(.nan, for: "BuiltIn")
        await coordinator.testingWaitUntilIdle()

        XCTAssertEqual(deviceProvider.volumeWrites, [1])
        await coordinator.shutdown()
    }

    func testLeaseContentionKeepsDeviceMonitoringAliveWithoutProcessWork() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [.unavailable(.leaseUnavailable)]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.devices.map(\.id), ["BuiltIn"])
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.stopCount, 0)
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [])
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
        XCTAssertEqual(fixture.engine.cleanupCount, 0)
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.authorizationAttemptCount, 0)
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertFalse(fixture.lifecycle.events.contains("processes.read"))
        XCTAssertEqual(
            fixture.coordinator.snapshot.processRuntimeError,
            .operationFailed(.leaseUnavailable)
        )
    }

    func testLeaseFailureExposesTruthfulGlobalErrorWithoutStoppingMonitor() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [.unavailable(.leaseFailed)]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)

        await fixture.coordinator.start()

        XCTAssertEqual(
            fixture.coordinator.snapshot.processRuntimeError,
            .operationFailed(.leaseFailed)
        )
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(fixture.monitor.stopCount, 0)
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testNoAudibleReconciliationAcquiresLeaseThenClearsStaleLeaseError() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [
            .unavailable(.leaseUnavailable),
            .ready(cleanupFailures: []),
        ]
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.5
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            engine: engine
        )
        await fixture.coordinator.start()
        XCTAssertEqual(
            fixture.coordinator.snapshot.processRuntimeError,
            .operationFailed(.leaseUnavailable)
        )

        fixture.processProvider.processes = []
        await fixture.emit([.processList])

        XCTAssertNil(fixture.coordinator.snapshot.processRuntimeError)
        XCTAssertNil(AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        ).processSection)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.engine.cleanupCount, 0)
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.stopCalls, [])
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.store.saveCount, 0)
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [])
        XCTAssertEqual(fixture.coordinator.snapshot.devices.map(\.id), ["BuiltIn"])
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.stopCount, 0)
    }

    func testNoAudibleReconciliationKeepsStaleLeaseErrorWhenRetryIsStillBusy() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [
            .unavailable(.leaseUnavailable),
            .unavailable(.leaseUnavailable),
        ]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)
        await fixture.coordinator.start()

        fixture.processProvider.processes = []
        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(
            fixture.coordinator.snapshot.processRuntimeError,
            .operationFailed(.leaseUnavailable)
        )
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testProcessReconciliationRetriesLeaseAndRestoresRows() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [
            .unavailable(.leaseUnavailable),
            .ready(cleanupFailures: []),
        ]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)
        await fixture.coordinator.start()

        XCTAssertEqual(fixture.processProvider.callCount, 0)

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertTrue(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertNil(fixture.coordinator.snapshot.processRuntimeError)
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.processProvider.callCount, 1)
    }

    func testServiceReconciliationRetriesLeaseAndRestoresRows() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [
            .unavailable(.leaseUnavailable),
            .ready(cleanupFailures: []),
        ]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)
        await fixture.coordinator.start()

        XCTAssertEqual(fixture.processProvider.callCount, 0)

        await fixture.emit([.serviceRestarted])

        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertNil(fixture.coordinator.snapshot.processRuntimeError)
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.processProvider.callCount, 1)
    }

    func testDeviceReconciliationRetriesLeaseAndRestoresRows() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [
            .unavailable(.leaseUnavailable),
            .ready(cleanupFailures: []),
        ]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)
        await fixture.coordinator.start()

        XCTAssertEqual(fixture.processProvider.callCount, 0)

        await fixture.emit([.deviceList])

        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertNil(fixture.coordinator.snapshot.processRuntimeError)
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.processProvider.callCount, 1)
    }

    func testProcessMutationsAreNoOpsWhileLeaseIsUnavailable() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [.unavailable(.leaseUnavailable)]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)
        await fixture.coordinator.start()

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        fixture.coordinator.setProcessMuted(true, for: 11)
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        fixture.coordinator.retry(processObjectID: 11)
        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.gainUpdateCalls.count, 0)
        XCTAssertEqual(fixture.engine.stopCalls.count, 0)
        XCTAssertEqual(fixture.store.saveCount, 0)
    }

    func testSupportedDefaultBrowsingDoesNotApplyOrAttemptAuthorization() async {
        let fixture = CoordinatorFixture(availability: .supported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.authorizationAttemptCount, 0)
    }

    func testExactPolicyHidesDeniedCurrentProcessRowsAndSection() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let preflight = AudioRoutePlanner()
        let allowed = try preflight.topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: devices
        ))
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [allowed]))
        )
        fixture.processProvider.processes = [
            .music(objectID: 11, outputDeviceIDs: [20]),
        ]

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.processProvider.callCount, 1)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertNil(AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        ).processSection)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
    }

    func testPersistedDeniedRouteHidesRowEvenWhenFollowOriginalIsAllowed() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let preflight = AudioRoutePlanner()
        let follow = try preflight.topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: devices
        ))
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.4,
            route: .explicit(targetDeviceUIDs: ["USB"])
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [follow]))
        )

        await fixture.coordinator.start()

        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
    }

    func testPersistedAllowedRouteRestoresWhenFollowOriginalIsDenied() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let preflight = AudioRoutePlanner()
        let explicit = try preflight.topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .explicit(targetDeviceUIDs: ["USB"]),
            devices: devices
        ))
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.4,
            route: .explicit(targetDeviceUIDs: ["USB"])
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [explicit]))
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].route, profile.route)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertEqual(fixture.engine.applyCount, 1)
    }

    func testFailedPersistedRestoreNeverConfirmsRequestedValues() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let preflight = AudioRoutePlanner()
        let explicit = try preflight.topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .explicit(targetDeviceUIDs: ["USB"]),
            devices: devices
        ))
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.4,
            route: .explicit(targetDeviceUIDs: ["USB"])
        )
        let engine = EngineFake()
        engine.nextError = .unsupportedFormat
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            engine: engine,
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [explicit]))
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        let row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(row.route, .followOriginal)
        XCTAssertEqual(row.volume, 1)
        XCTAssertEqual(row.pendingValues?.route, profile.route)
        XCTAssertEqual(row.error, .operationFailed(.unsupportedFormat))
        XCTAssertEqual(fixture.engine.applyCount, 1)
    }

    func testSupportedRuntimeWithNoAudibleProcessesPreparesOnceAndStaysHidden() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.processProvider.processes = []

        await fixture.coordinator.start()

        XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertNil(AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        ).processSection)
        await fixture.coordinator.shutdown()
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
    }

    func testSupportedNoAudibleObservationFailureStopsPreparedRuntime() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.processProvider.processes = []
        await fixture.coordinator.start()
        fixture.monitor.observationError = FixtureError.writeFailed

        await fixture.emit([.deviceList])

        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
        XCTAssertEqual(fixture.engine.stopAllCount, 1)
    }

    func testDifferentOSBuildFingerprintDoesNotExposeCurrentProcess() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let current = try AudioRoutePlanner().topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: devices
        ))
        let otherBuild = AudioRouteTopologyFingerprint(
            osBuild: current.osBuild + ".other",
            sourceDeviceUIDs: current.sourceDeviceUIDs,
            selectedTargetUIDs: current.selectedTargetUIDs,
            devices: current.devices
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [otherBuild]))
        )

        await fixture.coordinator.start()

        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
    }

    func testRouteTopologyProviderFailureKeepsProcessSectionHidden() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let allowed = try AudioRoutePlanner().topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: devices
        ))
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [allowed]))
        )
        fixture.deviceProvider.routeReadError = FixtureError.writeFailed

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.devices.map(\.id), ["BuiltIn"])
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
    }

    func testDifferentHardwareFingerprintDoesNotExposeCurrentProcess() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let allowed = try AudioRoutePlanner().topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: devices
        ))
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [allowed]))
        )
        fixture.deviceProvider.routeDescriptors = devices.map { device in
            guard device.uid == "BuiltIn" else { return device }
            return AudioRouteDevice(
                objectID: device.objectID,
                uid: device.uid,
                name: device.name,
                isAlive: device.isAlive,
                isAggregate: device.isAggregate,
                aggregateSubdeviceUIDs: device.aggregateSubdeviceUIDs,
                inputStreams: device.inputStreams,
                outputStreams: device.outputStreams,
                clockDomain: 999,
                transportType: device.transportType,
                modelUID: device.modelUID,
                driverIdentity: device.driverIdentity,
                aggregateComposition: device.aggregateComposition
            )
        }

        await fixture.coordinator.start()

        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
    }

    func testExactPolicyShowsOnlyPermittedNextRouteChoice() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let preflight = AudioRoutePlanner()
        func fingerprint(_ mode: AudioRouteMode) throws -> AudioRouteTopologyFingerprint {
            try preflight.topologyFingerprint(for: AudioRouteRequest(
                processObjectID: 11,
                processIdentifier: 101,
                generation: 1,
                sourceDeviceUIDs: ["BuiltIn"],
                systemDefaultOutputDeviceUID: nil,
                mode: mode,
                devices: devices
            ))
        }
        let policy = AudioRouteNativeValidationPolicy(validatedFingerprints: [
            try fingerprint(.followOriginal),
            try fingerprint(.explicit(targetDeviceUIDs: ["USB"])),
        ])
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: AudioRoutePlanner(policy: policy)
        )

        await fixture.coordinator.start()
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions.map(\.uid),
            ["BuiltIn", "USB"]
        )

        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions.map(\.uid),
            ["USB"],
            "Adding BuiltIn would create an unvalidated nearby fingerprint"
        )
        XCTAssertFalse(fixture.coordinator.snapshot.processes[0].routeOptions[0].isEnabled)
    }

    func testUnselectedUnavailableRouteIsNeverEnabled() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["BuiltIn"]),
            for: 11
        )
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.deviceProvider.setAlive(false, uid: "USB")

        await fixture.emit([.deviceList])

        XCTAssertNotEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions
                .first(where: { $0.uid == "USB" })?.isEnabled,
            true
        )
    }

    func testTopologyFingerprintDriftHidesPreviouslyAllowedProcessRow() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let preflight = AudioRoutePlanner()
        let allowed = try preflight.topologyFingerprint(for: AudioRouteRequest(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: devices
        ))
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [allowed]))
        )
        await fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])

        fixture.deviceProvider.routeDescriptors = devices.map { device in
            guard device.uid == "BuiltIn" else { return device }
            return AudioRouteDevice(
                objectID: device.objectID,
                uid: device.uid,
                name: device.name,
                isAlive: device.isAlive,
                isAggregate: device.isAggregate,
                aggregateSubdeviceUIDs: device.aggregateSubdeviceUIDs,
                inputStreams: device.inputStreams,
                outputStreams: device.outputStreams,
                clockDomain: 999,
                transportType: device.transportType,
                modelUID: device.modelUID,
                driverIdentity: device.driverIdentity,
                aggregateComposition: device.aggregateComposition
            )
        }

        await fixture.emit([.deviceList])

        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
        XCTAssertNil(AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        ).processSection)
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

    func testSelectedProcessIdentifierReachesPlannedRoute() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.lastAppliedPlan?.processIdentifier, 101)
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

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])
        XCTAssertEqual(fixture.engine.gainUpdateCalls, [
            .init(processObjectID: 11, gain: .init(volume: 0.6, isMuted: false)),
            .init(processObjectID: 11, gain: .init(volume: 0.4, isMuted: false)),
        ])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.6)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .persistenceFailed)
    }

    func testRunningSessionVolumeAndMuteUseGainUpdatesWithoutRebuild() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let session = fixture.coordinator.snapshot.processes[0].session
        let prepareRuntimeCount = fixture.engine.prepareRuntimeCount

        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.coordinator.setProcessMuted(true, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])
        XCTAssertEqual(fixture.engine.gainUpdateCalls, [
            .init(processObjectID: 11, gain: .init(volume: 0.6, isMuted: false)),
            .init(processObjectID: 11, gain: .init(volume: 0.6, isMuted: true)),
        ])
        XCTAssertEqual(fixture.engine.stopCalls, [])
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, prepareRuntimeCount)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, session)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.6)
        XCTAssertTrue(fixture.coordinator.snapshot.processes[0].isMuted)
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles["com.example.music"],
            AudioProcessProfile(
                bundleIdentifier: "com.example.music",
                volume: 0.6,
                isMuted: true
            )
        )
    }

    func testGainOnlyPreservesRouteOptionsWithoutAnyPlannerQuery() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let fixedBuild = "gain-fast-path-build"
        let fingerprintPlanner = AudioRoutePlanner(
            policy: .conservative,
            osBuildProvider: { fixedBuild }
        )
        let modes: [AudioRouteMode] = [
            .followOriginal,
            .explicit(targetDeviceUIDs: ["USB"]),
        ]
        let fingerprints = try Set(modes.map { mode in
            try fingerprintPlanner.topologyFingerprint(for: AudioRouteRequest(
                processObjectID: 11,
                processIdentifier: 101,
                generation: 1,
                sourceDeviceUIDs: ["BuiltIn"],
                systemDefaultOutputDeviceUID: nil,
                mode: mode,
                devices: devices
            ))
        })
        let queries = PlannerQueryCounter()
        let planner = AudioRoutePlanner(
            policy: .init(validatedFingerprints: fingerprints),
            osBuildProvider: {
                queries.record()
                return fixedBuild
            }
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: planner
        )
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let routeOptions = fixture.coordinator.snapshot.processes[0].routeOptions
        let queryCount = queries.count

        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(queries.count, queryCount)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].routeOptions, routeOptions)

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: 11
        )
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertGreaterThan(queries.count, queryCount)
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
    }

    func testRequestedShutdownRejectsEveryMutationAndRestoresPendingGainUI() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        await fixture.engine.blockGainUpdateCall(1)
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.engine.waitUntilGainUpdateCount(1)

        fixture.coordinator.requestShutdown()
        fixture.deviceProvider.snapshotVolume = 0.9
        fixture.coordinator.retryDevice("BuiltIn")
        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        fixture.coordinator.setProcessVolume(0.7, for: 11)
        fixture.coordinator.setProcessMuted(true, for: 11)
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: 11
        )
        fixture.coordinator.retry(processObjectID: 11)
        fixture.coordinator.reset(processObjectID: 11)

        let row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(row.volume, 0.4)
        XCTAssertFalse(row.isMuted)
        XCTAssertEqual(row.route, .followOriginal)
        XCTAssertNil(row.pendingValues)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.5)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, false)
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])

        let shutdown = Task { @MainActor in await fixture.coordinator.shutdown() }
        await Task.yield()

        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        await fixture.engine.resumeGainUpdates()
        await shutdown.value

        XCTAssertEqual(fixture.engine.gainUpdateCalls.count, 1)
        XCTAssertEqual(fixture.engine.shutdownCount, 1)
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [])
        XCTAssertEqual(fixture.deviceProvider.muteWrites, [])
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles["com.example.music"]?.volume,
            0.4
        )
    }

    func testDirectShutdownWaitsForBlockedGainAndNeverPersistsAfterEngineShutdown() async throws {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        await fixture.engine.blockGainUpdateCall(1)
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.engine.waitUntilGainUpdateCount(1)

        let shutdown = Task { @MainActor in await fixture.coordinator.shutdown() }
        await Task.yield()

        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        await fixture.engine.resumeGainUpdates()
        await shutdown.value

        XCTAssertEqual(fixture.engine.gainUpdateCalls.count, 1)
        XCTAssertEqual(fixture.engine.shutdownCount, 1)
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertLessThan(
            try XCTUnwrap(fixture.lifecycle.events.firstIndex(of: "engine.updateGain")),
            try XCTUnwrap(fixture.lifecycle.events.firstIndex(of: "engine.shutdown"))
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles["com.example.music"]?.volume,
            0.4
        )
    }

    func testBlockedGainCompletesBeforeExactObjectExitStopWithoutStalePersistence() async throws {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        await fixture.engine.blockGainUpdateCall(1)
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.engine.waitUntilGainUpdateCount(1)
        fixture.processProvider.processes = []
        let rowRetired = expectation(description: "old row retired before stop")
        let cancellable = fixture.coordinator.snapshotPublisher
            .filter { $0.processes.isEmpty }
            .first()
            .sink { _ in rowRetired.fulfill() }

        let reconciliation = Task { @MainActor in
            await fixture.emit([.processList])
        }
        await fulfillment(of: [rowRetired], timeout: 1)

        XCTAssertEqual(fixture.engine.stopCalls, [])
        await fixture.engine.resumeGainUpdates()
        await reconciliation.value

        XCTAssertEqual(fixture.engine.stopCalls, [.init(processObjectID: 11, generation: 2)])
        XCTAssertLessThan(
            try XCTUnwrap(fixture.lifecycle.events.firstIndex(of: "engine.updateGain")),
            try XCTUnwrap(fixture.lifecycle.events.firstIndex(of: "engine.stop"))
        )
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles["com.example.music"]?.volume,
            0.4
        )
        withExtendedLifetime(cancellable) {}
    }

    func testBlockedGainCompletesBeforeSamePIDReplacementAndNewObjectRestoresProfile() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        await fixture.engine.blockGainUpdateCall(1)
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.engine.waitUntilGainUpdateCount(1)
        fixture.processProvider.processes = [.music(objectID: 22)]
        let rowRetired = expectation(description: "old row retired before replacement stop")
        let cancellable = fixture.coordinator.snapshotPublisher
            .filter { $0.processes.isEmpty }
            .first()
            .sink { _ in rowRetired.fulfill() }

        let reconciliation = Task { @MainActor in
            await fixture.emit([.processList])
        }
        await fulfillment(of: [rowRetired], timeout: 1)

        XCTAssertEqual(fixture.engine.stopCalls, [])
        await fixture.engine.resumeGainUpdates()
        await reconciliation.value
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.stopCalls, [.init(processObjectID: 11, generation: 2)])
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [22])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertEqual(fixture.engine.plans.map(\.processObjectID), [11, 22])
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles["com.example.music"]?.volume,
            0.4
        )
        withExtendedLifetime(cancellable) {}
    }

    func testRunningSessionSliderBurstCoalescesWithoutGenerationChange() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let session = fixture.coordinator.snapshot.processes[0].session
        await fixture.engine.blockGainUpdateCall(1)

        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.engine.waitUntilGainUpdateCount(1)
        fixture.coordinator.setProcessVolume(0.6, for: 11)
        fixture.coordinator.setProcessVolume(0.7, for: 11)
        await fixture.engine.resumeGainUpdates()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])
        XCTAssertEqual(fixture.engine.gainUpdateCalls, [
            .init(processObjectID: 11, gain: .init(volume: 0.5, isMuted: false)),
            .init(processObjectID: 11, gain: .init(volume: 0.7, isMuted: false)),
        ])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, session)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.7)
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles["com.example.music"]?.volume,
            0.7
        )
    }

    func testRouteChangeWaitsForCanceledGainThenRebuildsNextGeneration() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        await fixture.engine.blockGainUpdateCall(1)

        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.engine.waitUntilGainUpdateCount(1)
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: 11
        )

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])
        await fixture.engine.resumeGainUpdates()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.gainUpdateCalls, [
            .init(processObjectID: 11, gain: .init(volume: 0.5, isMuted: false)),
        ])
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.generation, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.5)
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["USB"])
        )
    }

    func testOlderFailedGainRollbackFinishesBeforeNewerSuccess() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveFailuresRemaining = 1
        await fixture.engine.blockGainUpdateCall(2)

        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.engine.waitUntilGainUpdateCount(2)
        fixture.coordinator.setProcessVolume(0.7, for: 11)
        await fixture.engine.resumeGainUpdates()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])
        XCTAssertEqual(fixture.engine.gainUpdateCalls, [
            .init(processObjectID: 11, gain: .init(volume: 0.6, isMuted: false)),
            .init(processObjectID: 11, gain: .init(volume: 0.4, isMuted: false)),
            .init(processObjectID: 11, gain: .init(volume: 0.7, isMuted: false)),
        ])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.7)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles["com.example.music"]?.volume,
            0.7
        )
    }

    func testSamePIDNewObjectStopsOldSessionAndPublishesNewIdentity() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.processProvider.processes = [.music(objectID: 22)]

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [22])
    }

    func testExactObjectRefreshPreservesSessionPendingValuesAndError() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.nextError = .unsupportedFormat
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let before = fixture.coordinator.snapshot.processes[0]

        await fixture.emit([.processList])

        let after = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(after.session, before.session)
        XCTAssertEqual(after.pendingValues, before.pendingValues)
        XCTAssertEqual(after.error, before.error)
    }

    func testEveryDisappearingProcessObjectIsStoppedFailClosed() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.processProvider.processes = []

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
    }

    func testDisappearingObjectRetiresBeforeStopAndReuseStartsAfterTombstone() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        await fixture.engine.blockApplyReturn(1)
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.engine.waitUntilApplyReturnCount(1)
        await fixture.engine.blockStops()
        fixture.processProvider.processes = []
        let token = fixture.monitor.emit([.processList])
        await fixture.engine.waitUntilStopCount(1)

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        fixture.coordinator.setProcessVolume(0.8, for: 11)
        await fixture.engine.resumeApplyReturns()
        await fixture.engine.resumeStops()
        await fixture.coordinator.testingWaitForReconciliation(token: token)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.applyCount, 1)
        XCTAssertNil(fixture.store.savedPreferences.audioProcessProfiles["com.example.music"])

        fixture.processProvider.processes = [.music(objectID: 11)]
        await fixture.emit([.processList])
        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.applyCount, 2)
        XCTAssertGreaterThan(
            fixture.engine.plans.last!.generation,
            fixture.engine.stoppedGenerations.last!
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.6)
    }

    func testReplacementObjectRestoresSavedBundleProfile() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.35
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )
        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.processProvider.processes = [.music(objectID: 22)]

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.engine.plans.last?.processObjectID, 22)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.35)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
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
        await fixture.emitEngine(newest)
        await fixture.emitEngine(.init(
            processObjectID: 11,
            generation: 1,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: 1,
            emissionOrdinal: 9
        ))
        await fixture.emitEngine(.init(
            processObjectID: 11,
            generation: 2,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: 2,
            emissionOrdinal: 1
        ))
        await fixture.emitEngine(newest)

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, newest)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testEngineSnapshotAckWaitsForExactSnapshotOrder() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        let unrelated = ProcessTapSessionSnapshot(
            processObjectID: 11,
            generation: 1,
            state: .preparing,
            error: nil,
            commandSequence: 10,
            emissionOrdinal: 0
        )
        let target = ProcessTapSessionSnapshot(
            processObjectID: 11,
            generation: 1,
            state: .running,
            error: nil,
            commandSequence: 20,
            emissionOrdinal: 0
        )
        var acknowledged = false
        let started = expectation(description: "exact snapshot waiter started")
        let waiter = Task { @MainActor in
            started.fulfill()
            await fixture.coordinator.testingWaitForEngineSnapshot(
                processObjectID: target.processObjectID,
                order: target.order
            )
            acknowledged = true
        }
        await fulfillment(of: [started], timeout: 1)

        await fixture.emitEngine(unrelated)
        XCTAssertFalse(acknowledged)
        await fixture.emitEngine(target)
        await waiter.value
        XCTAssertTrue(acknowledged)
    }

    func testReconciliationAckWaitsForTargetTokenBehindQueuedEvent() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        _ = fixture.monitor.emit([.defaultOutputDevice])
        fixture.processProvider.processes = []
        await fixture.engine.blockStops()
        let targetToken = fixture.monitor.emit([.processList])
        await fixture.engine.waitUntilStopCount(1)
        var acknowledged = false
        let started = expectation(description: "target token waiter started")
        let waiter = Task { @MainActor in
            started.fulfill()
            await fixture.coordinator.testingWaitForReconciliation(token: targetToken)
            acknowledged = true
        }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertFalse(acknowledged)
        await fixture.engine.resumeStops()
        await waiter.value
        XCTAssertTrue(acknowledged)
    }

    func testHigherOrderSnapshotFromLowerGenerationIsRejected() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let accepted = fixture.coordinator.snapshot.processes[0].session

        await fixture.emitEngine(.init(
            processObjectID: 11,
            generation: 0,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: accepted.commandSequence + 100,
            emissionOrdinal: 0
        ))

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, accepted)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testObserverSnapshotIsAcceptedBeforeAsyncCommandReturns() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        await fixture.engine.blockApplyReturn(1)

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.engine.waitUntilApplyReturnCount(1)
        let emitted = fixture.engine.lastProducedSnapshot!
        await fixture.coordinator.testingWaitForEngineSnapshot(
            processObjectID: emitted.processObjectID,
            order: emitted.order
        )

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        await fixture.engine.resumeApplyReturns()
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
    }

    func testAsyncCommandReturnIsAcceptedBeforeDuplicateObserverSnapshot() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.deferApplyObserver(1)

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let accepted = fixture.coordinator.snapshot.processes[0].session
        fixture.engine.deliverDeferredObservers()
        await fixture.coordinator.testingWaitForEngineSnapshot(
            processObjectID: accepted.processObjectID,
            order: accepted.order
        )

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, accepted)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testResetCommitsOnlyAfterAcceptedIdleStop() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let stopError = ProcessTapEngineError.operationFailed(operation: .stopDevice, status: -1)
        fixture.engine.scriptedStopResults = [(.failed, stopError)]

        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues, .default)
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .operationFailed(stopError)
        )
    }

    func testCanceledResetCannotOverwriteNewerRunningIntent() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        await fixture.engine.blockStops()

        fixture.coordinator.reset(processObjectID: 11)
        await fixture.engine.waitUntilStopCount(1)
        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitForProcessTask(11)
        await fixture.engine.resumeStops()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.6)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
    }

    func testFailedPreviousRuleRollbackStopsAndProvesIdle() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveFailuresRemaining = 1
        fixture.engine.scriptedApplyResults = [
            (.running, nil),
            (.failed, .unsupportedFormat),
        ]

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: 11
        )
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs.last, 11)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .idle)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].pendingValues?.route,
            .explicit(targetDeviceUIDs: ["USB"])
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .persistenceFailed)
    }

    func testSupersededPersistenceRollbackCannotOverwriteNewerRule() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveFailuresRemaining = 1
        await fixture.engine.blockApplyCall(3)

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: 11
        )
        await fixture.engine.waitUntilApplyCount(3)
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["BuiltIn"]),
            for: 11
        )
        await fixture.coordinator.testingWaitForProcessTask(11)
        await fixture.engine.resumeApplies()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["BuiltIn"])
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testShutdownStopsMonitorBeforeAwaitedEngineShutdown() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        await fixture.coordinator.shutdown()

        XCTAssertEqual(fixture.lifecycle.events.suffix(2), ["monitor.stop", "engine.shutdown"])
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
        await fixture.emit([.device(20, .liveness)])

        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn"])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["BuiltIn", "USB"])
        )

        fixture.deviceProvider.setAlive(true, uid: "USB")
        await fixture.emit([.device(20, .liveness)])
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
        await fixture.emit([.device(20, .liveness)])
        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
    }

    func testSavedMissingRouteImmediatelyBuildsSelectedUnavailableOption() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.5,
            route: .explicit(targetDeviceUIDs: ["Missing"])
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions.first(where: {
                $0.uid == "Missing"
            }),
            AudioRouteDeviceOption(
                uid: "Missing",
                name: "Missing",
                isAvailable: false,
                isSelected: true,
                isEnabled: false
            )
        )
    }

    func testUserRouteIntentImmediatelyRebuildsAvailableAndMissingSelections() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB", "Missing"]),
            for: 11
        )

        let options = fixture.coordinator.snapshot.processes[0].routeOptions
        XCTAssertEqual(options.first(where: { $0.uid == "USB" })?.isSelected, true)
        XCTAssertEqual(
            options.first(where: { $0.uid == "Missing" }),
            AudioRouteDeviceOption(
                uid: "Missing",
                name: "Missing",
                isAvailable: false,
                isSelected: true
            )
        )
        await fixture.coordinator.testingWaitUntilIdle()
    }

    func testFailedAndResetRouteWritesRebuildConfirmedRouteOptions() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.engine.nextError = .unsupportedFormat

        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["BuiltIn"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        var row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(row.route, .explicit(targetDeviceUIDs: ["USB"]))
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "USB" })?.isSelected, true)
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "BuiltIn" })?.isSelected, false)

        fixture.engine.nextError = nil
        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(row.route, .followOriginal)
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "BuiltIn" })?.isSelected, true)
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "USB" })?.isSelected, false)
    }

    func testLossOfAllExplicitTargetsStopsTapAndRetainsUnavailableRoute() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        fixture.deviceProvider.setAlive(false, uid: "USB")
        await fixture.emit([.deviceList])

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

    func testLossOfAllTargetsCommitsUnavailableOnlyAfterAcceptedIdleStop() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let stopError = ProcessTapEngineError.operationFailed(operation: .stopDevice, status: -1)
        fixture.engine.scriptedStopResults = [(.failed, stopError)]

        fixture.deviceProvider.setAlive(false, uid: "USB")
        await fixture.emit([.deviceList])

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .failed)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .operationFailed(stopError))
    }

    func testUnavailableRouteUsesFailedStopReturnBeforeItsObserverSnapshot() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        let stopError = ProcessTapEngineError.operationFailed(operation: .stopDevice, status: -1)
        fixture.engine.scriptedStopResults = [(.failed, stopError)]
        fixture.engine.deferStopObserver(1)

        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["Missing"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .failed)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .operationFailed(stopError))

        fixture.engine.deliverDeferredObservers()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .failed)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .operationFailed(stopError))
    }

    func testSourceOutputChangeRebuildsFollowOriginalButDefaultChangeDoesNotRebuildExplicit() async {
        let followFixture = CoordinatorFixture(availability: .supported)
        await followFixture.coordinator.start()
        followFixture.coordinator.setProcessVolume(0.5, for: 11)
        await followFixture.coordinator.testingWaitUntilIdle()
        followFixture.processProvider.processes = [.music(objectID: 11, outputDeviceIDs: [20])]
        await followFixture.emit([.process(11, .outputDevices)])
        XCTAssertEqual(followFixture.engine.plans.last?.selectedTargetUIDs, ["USB"])

        followFixture.processProvider.processes = [.music(objectID: 11, outputDeviceIDs: [10])]
        await followFixture.emit([.defaultOutputDevice])
        XCTAssertEqual(followFixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn"])

        let explicitFixture = CoordinatorFixture(availability: .supported)
        await explicitFixture.coordinator.start()
        explicitFixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await explicitFixture.coordinator.testingWaitUntilIdle()
        let applyCount = explicitFixture.engine.plans.count
        await explicitFixture.emit([.defaultOutputDevice])
        XCTAssertEqual(explicitFixture.engine.plans.count, applyCount)
        XCTAssertEqual(explicitFixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
    }

    func testSampleRateChangeRebuildsOnlySessionUsingDevice() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let applyCount = fixture.engine.plans.count

        await fixture.emit([.device(10, .nominalSampleRate)])
        XCTAssertEqual(fixture.engine.plans.count, applyCount + 1)

        await fixture.emit([.device(20, .nominalSampleRate)])
        XCTAssertEqual(fixture.engine.plans.count, applyCount + 1)
    }

    func testServiceRestartStopsRefreshesPreparesAndRestores() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let initialApplyCount = fixture.engine.plans.count

        await fixture.emit([.serviceRestarted])

        XCTAssertTrue(fixture.lifecycle.events.contains("engine.stopAll"))
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.engine.stopAllCount, 1)
        XCTAssertEqual(fixture.engine.shutdownCount, 0)
        XCTAssertGreaterThan(fixture.engine.plans.count, initialApplyCount)
    }

    func testServiceRestartLeaseFailureClearsRowsAndMonitorObjects() async {
        let engine = EngineFake()
        engine.scriptedPreparationResults = [
            .ready(cleanupFailures: []),
            .unavailable(.leaseUnavailable),
        ]
        let fixture = CoordinatorFixture(availability: .supported, engine: engine)
        await fixture.coordinator.start()
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])

        await fixture.emit([.serviceRestarted])

        XCTAssertEqual(fixture.engine.stopAllCount, 1)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processRuntimeError,
            .operationFailed(.leaseUnavailable)
        )
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [])
    }

    func testServiceRestartRestoresBundlelessConfirmedRule() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            bundleIdentifier: nil
        )
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let initialApplyCount = fixture.engine.plans.count

        await fixture.emit([.serviceRestarted])

        XCTAssertEqual(fixture.engine.plans.count, initialApplyCount + 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
    }

    func testUnsupportedServiceRestartNeverEnumeratesProcesses() async {
        let fixture = CoordinatorFixture(availability: .unsupported)
        await fixture.coordinator.start()

        await fixture.emit([.serviceRestarted])

        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
        XCTAssertEqual(fixture.lifecycle.events.filter { $0 == "routes.read" }.count, 0)
        XCTAssertEqual(fixture.lifecycle.events.filter { $0 == "devices.read" }.count, 2)
    }

    func testUnsupportedShutdownDoesNotStartProcessEngineTeardown() async {
        let fixture = CoordinatorFixture(availability: .unsupported)
        await fixture.coordinator.start()

        await fixture.coordinator.shutdown()

        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
    }

    func testUnsupportedOrdinaryMonitorChangesNeverEnumerateOrObserveProcesses() async {
        let fixture = CoordinatorFixture(availability: .unsupported)
        await fixture.coordinator.start()
        fixture.deviceProvider.snapshotVolume = 0.73

        await fixture.emit([
            .processList,
            .defaultOutputDevice,
            .process(11, .outputDevices),
        ])

        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.73)
        XCTAssertFalse(fixture.lifecycle.events.contains("routes.read"))
    }

    func testUnsupportedObservationFailureNeverStartsProcessEngineTeardown() async {
        let fixture = CoordinatorFixture(availability: .unsupported)
        await fixture.coordinator.start()
        fixture.monitor.observationError = FixtureError.writeFailed

        await fixture.emit([.deviceList])

        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
        XCTAssertEqual(fixture.processProvider.callCount, 0)
    }

    func testStartPreparesRuntimeBeforeMonitorObserveAndRestore() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.5
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(
            fixture.lifecycle.events.prefix(7),
            [
                "monitor.start",
                "routes.read",
                "devices.read",
                "engine.prepareRuntime",
                "processes.read",
                "monitor.observe",
                "engine.apply",
            ]
        )
    }

    func testCanceledStartFinishingPreparationAfterShutdownDoesNotApplyProcessRule() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [
                "com.example.music": AudioProcessProfile(
                    bundleIdentifier: "com.example.music",
                    volume: 0.5
                ),
            ]
        )
        await fixture.engine.blockPrepareRuntime()
        let startTask = Task { @MainActor in
            await fixture.coordinator.start()
        }
        await fixture.engine.waitUntilPrepareRuntimeCount(1)

        startTask.cancel()
        await fixture.coordinator.shutdown()
        XCTAssertEqual(fixture.engine.shutdownCount, 1)
        await fixture.engine.resumePrepareRuntime()
        await startTask.value

        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.stopCount, 1)
        XCTAssertFalse(fixture.lifecycle.events.contains("monitor.observe"))
        XCTAssertTrue(fixture.lifecycle.events.contains("routes.read"))
        XCTAssertTrue(fixture.lifecycle.events.contains("devices.read"))
        XCTAssertFalse(fixture.lifecycle.events.contains("processes.read"))
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testCanceledPrepareWithoutShutdownRetriesRuntimePreparation() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.engine.blockPrepareRuntime()
        let startTask = Task { @MainActor in
            await fixture.coordinator.start()
        }
        await fixture.engine.waitUntilPrepareRuntimeCount(1)

        startTask.cancel()
        await fixture.engine.resumePrepareRuntime()
        await startTask.value

        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.stopCount, 1)
        XCTAssertEqual(fixture.engine.applyCount, 0)

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
    }

    func testChangeBufferedWhileStartingMonitorIsReconciled() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.processProvider.scriptedProcesses = [
            [.music(objectID: 11)],
            [.music(objectID: 22)],
        ]
        fixture.deviceProvider.onRouteRead = {
            fixture.monitor.emit([.processList])
        }
        let reconciled = expectation(description: "startup change reconciled")
        let cancellable = fixture.coordinator.snapshotPublisher
            .filter { $0.processes.map(\.id) == [22] }
            .first()
            .sink { _ in reconciled.fulfill() }

        await fixture.coordinator.start()
        await fulfillment(of: [reconciled], timeout: 0.1)

        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [22])
        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        withExtendedLifetime(cancellable) {}
    }

    func testMissingSelectedRouteRemainsVisibleAsUnavailableOption() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.deviceProvider.removeRouteDevice(uid: "USB")

        await fixture.emit([.deviceList])

        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions.first(where: { $0.uid == "USB" }),
            AudioRouteDeviceOption(
                uid: "USB",
                name: "USB",
                isAvailable: false,
                isSelected: true,
                isEnabled: false
            )
        )
    }

    func testMonitorStartFailureFailsClosedAndStartCanRetry() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.monitor.startError = FixtureError.writeFailed

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        fixture.monitor.startError = nil
        await fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.monitor.startCount, 2)
    }

    func testMonitorObservationFailureFailsClosedAndStartCanRetry() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.monitor.observationError = FixtureError.writeFailed

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        fixture.monitor.observationError = nil
        await fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.monitor.startCount, 2)
    }

    func testRuntimeObservationFailureStopsRulesAndRetryRestoresBundlelessRule() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            bundleIdentifier: nil
        )
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let applyCount = fixture.engine.applyCount
        fixture.monitor.observationError = FixtureError.writeFailed

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertTrue(fixture.lifecycle.events.contains("engine.stopAll"))
        fixture.monitor.observationError = nil
        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.monitor.startCount, 2)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 2)
        XCTAssertEqual(fixture.engine.applyCount, applyCount + 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
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

    func testDeviceVolumeAndMuteUseIndependentTasksAndMergeLatestConfirmation() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.deviceProvider.confirmedVolume = 0.73
        fixture.deviceProvider.confirmedMute = true

        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        await delay.waitUntilCallCount(1)
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        await fixture.coordinator.testingWaitForDeviceMute("BuiltIn")
        await delay.resumeAll()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [0.8])
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.73)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)
    }

    func testFailedDeviceWritesRestoreLatestRefreshInsteadOfCapturedProperties() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.deviceProvider.volumeWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        await delay.waitUntilCallCount(1)
        fixture.deviceProvider.snapshotVolume = 0.61
        fixture.coordinator.retryDevice("BuiltIn")
        await delay.resumeAll()
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.61)

        fixture.deviceProvider.muteWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        fixture.deviceProvider.snapshotMute = true
        fixture.coordinator.retryDevice("BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)
    }

    func testRapidMuteAndProcessIntentsSkipCanceledWorkBeforeHAL() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        fixture.coordinator.setDeviceMuted(false, for: "BuiltIn")
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.deviceProvider.muteWrites, [true])
        XCTAssertEqual(fixture.engine.gains.map(\.volume), [0.6])
    }

    func testShutdownCancelsPendingSliderWrite() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.coordinator.setDeviceVolume(0.9, for: "BuiltIn")
        await delay.waitUntilCallCount(1)

        let shutdown = Task { @MainActor in await fixture.coordinator.shutdown() }
        await delay.resumeAll()
        await shutdown.value

        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [])
    }

    func testShutdownAwaitsCanceledDeviceTaskBeforeStoppingEngine() async {
        let delay = ControlledShutdownDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.coordinator.setDeviceVolume(0.9, for: "BuiltIn")
        await delay.waitUntilEntered()

        let shutdown = Task { @MainActor in await fixture.coordinator.shutdown() }
        await delay.waitUntilCanceled()

        XCTAssertFalse(fixture.lifecycle.events.contains("engine.shutdown"))
        await delay.release()
        await shutdown.value
        XCTAssertTrue(fixture.lifecycle.events.contains("engine.shutdown"))
        XCTAssertEqual(fixture.engine.shutdownCount, 1)
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
    }

    func testConcurrentShutdownWaitsForTheFirstShutdownToFinish() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        await fixture.engine.blockShutdown()

        let firstShutdown = Task { @MainActor in
            await fixture.coordinator.shutdown()
        }
        await fixture.engine.waitUntilShutdownCount(1)

        let secondShutdownReturned = expectation(description: "second shutdown returned")
        secondShutdownReturned.isInverted = true
        let secondShutdown = Task { @MainActor in
            await fixture.coordinator.shutdown()
            secondShutdownReturned.fulfill()
        }
        for _ in 0..<5 { await Task.yield() }
        await fulfillment(of: [secondShutdownReturned], timeout: 0.05)

        await fixture.engine.resumeShutdown()
        await firstShutdown.value
        await secondShutdown.value

        XCTAssertEqual(fixture.engine.shutdownCount, 1)
    }

    func testResetPersistenceFailureRestoresPreviousRunningRuleAndPublishesError() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveError = FixtureError.writeFailed

        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        let row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 3])
        XCTAssertEqual(row.volume, 0.4)
        XCTAssertEqual(row.session.state, .running)
        XCTAssertEqual(row.pendingValues, .default)
        XCTAssertEqual(row.error, .persistenceFailed)
    }

    func testRunningSessionWithMissingExplicitRouteStopsAndPublishesUnavailableState() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["Missing"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        let row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(row.session.state, .idle)
        XCTAssertEqual(row.route, .explicit(targetDeviceUIDs: ["Missing"]))
        XCTAssertEqual(row.pendingValues?.route, .explicit(targetDeviceUIDs: ["Missing"]))
        XCTAssertEqual(row.error, .targetUnavailable(["Missing"]))
    }

    func testDeniedRoutePlanningPublishesTypedErrorWithoutCallingEngine() async throws {
        let devices = DeviceProviderFake().routeDescriptors
        let preflight = AudioRoutePlanner()
        let allowed = try preflight.topologyFingerprint(for: .init(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .followOriginal,
            devices: devices
        ))
        let denied = try preflight.topologyFingerprint(for: .init(
            processObjectID: 11,
            processIdentifier: 101,
            generation: 1,
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: nil,
            mode: .explicit(targetDeviceUIDs: ["USB"]),
            devices: devices
        ))
        let fixture = CoordinatorFixture(
            availability: .supported,
            planner: AudioRoutePlanner(policy: .init(validatedFingerprints: [allowed]))
        )
        await fixture.coordinator.start()

        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        let row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(row.pendingValues?.route, .explicit(targetDeviceUIDs: ["USB"]))
        XCTAssertEqual(row.error, .routePlanning(.nativeValidationRequired(denied)))
    }

    func testReconnectedBundlelessExplicitRouteRebuildsUnavailableSession() async {
        let fixture = CoordinatorFixture(availability: .supported, bundleIdentifier: nil)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        fixture.deviceProvider.setAlive(false, uid: "USB")
        await fixture.emit([.device(20, .liveness)])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .targetUnavailable(["USB"])
        )

        let applyCountBeforeReconnect = fixture.engine.applyCount
        fixture.deviceProvider.setAlive(true, uid: "USB")
        await fixture.emit([.device(20, .liveness)])

        let row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(fixture.engine.applyCount, applyCountBeforeReconnect + 1)
        XCTAssertEqual(row.route, .explicit(targetDeviceUIDs: ["USB"]))
        XCTAssertEqual(row.session.state, .running)
        XCTAssertNil(row.error)
    }

    func testSampleRateChangeSkipsDefaultProcessSession() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        await fixture.emit([.device(10, .nominalSampleRate)])

        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .idle)
    }

    func testSampleRateChangeForUnknownDeviceDoesNotRebuildExplicitRoute() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let applyCount = fixture.engine.applyCount

        await fixture.emit([.device(999, .nominalSampleRate)])

        XCTAssertEqual(fixture.engine.applyCount, applyCount)
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["USB"])
        )
    }

    func testCoordinatorDeallocatesAfterPopoverObservationEnds() async {
        weak var weakCoordinator: AudioControlCoordinator?
        let engine = EngineFake()
        let terminated = expectation(description: "engine snapshot consumer terminated")
        engine.onStreamTermination { terminated.fulfill() }
        var fixture: CoordinatorFixture? = CoordinatorFixture(
            availability: .supported,
            engine: engine
        )
        await fixture?.coordinator.start()
        weakCoordinator = fixture?.coordinator
        var cancellable = fixture?.coordinator.snapshotPublisher.sink { _ in }

        cancellable = nil
        fixture = nil
        await fulfillment(of: [terminated], timeout: 1)

        XCTAssertNil(cancellable)
        XCTAssertNil(weakCoordinator)
    }
}
