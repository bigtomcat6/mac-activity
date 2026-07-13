import AppKit
import CoreAudio
import MacActivityCore
import XCTest

@testable import MacActivityApp

@MainActor
final class AudioControlComponentTests: XCTestCase {
    func testExplicitDisconnectRebuildsWithRemainingTargetAndKeepsProfileUIDs() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB", "HDMI"]),
            for: fixture.player.processObjectID
        )
        await fixture.finishPendingCommands()

        fixture.disconnect(uid: "HDMI")
        fixture.emit([.deviceList, .device(30, .liveness)])
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.lastAppliedPlan?.selectedTargetUIDs, ["USB"])
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.engine.gains, [
            .init(volume: 1, isMuted: false),
            .init(volume: 1, isMuted: false),
        ])
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(route: .explicit(targetDeviceUIDs: ["USB", "HDMI"]))
        )
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions.first(where: {
                $0.uid == "HDMI"
            }),
            .init(uid: "HDMI", name: "HDMI", isAvailable: false, isSelected: true)
        )
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .targetUnavailable(["HDMI"])
        )
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testLossOfEveryExplicitTargetStopsTapWithoutDefaultFallback() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: fixture.player.processObjectID
        )
        await fixture.finishPendingCommands()

        fixture.disconnect(uid: "USB")
        fixture.emit([.deviceList])
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.stopCalls, [.init(processObjectID: 11, generation: 2)])
        XCTAssertFalse(fixture.engine.plans.contains {
            $0.selectedTargetUIDs.contains("BuiltIn")
        })
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(route: .explicit(targetDeviceUIDs: ["USB"]))
        )
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .targetUnavailable(["USB"])
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .idle)
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testSourceAndSystemDefaultChangesHaveDifferentSemantics() async {
        let follow = AudioControlComponentFixture()
        await follow.start()
        follow.coordinator.setProcessVolume(0.5, for: follow.player.processObjectID)
        await follow.finishPendingCommands()
        follow.changeSource(to: "USB")
        follow.emit([.process(follow.player.processObjectID, .outputDevices)])
        await follow.finishPendingCommands()

        XCTAssertEqual(follow.engine.plans.map(\.selectedTargetUIDs), [["BuiltIn"], ["USB"]])
        XCTAssertEqual(
            follow.preferences.state.audioProcessProfiles[follow.bundleIdentifier],
            follow.profile(volume: 0.5)
        )
        XCTAssertEqual(follow.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(follow.monitor.observedProcessObjectIDs, [11])

        let explicit = AudioControlComponentFixture()
        await explicit.start()
        explicit.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["HDMI"]),
            for: explicit.player.processObjectID
        )
        await explicit.finishPendingCommands()
        explicit.emit([.defaultOutputDevice])
        await explicit.finishPendingCommands()

        XCTAssertEqual(explicit.engine.plans.map(\.selectedTargetUIDs), [["HDMI"]])
        XCTAssertEqual(
            explicit.preferences.state.audioProcessProfiles[explicit.bundleIdentifier],
            explicit.profile(route: .explicit(targetDeviceUIDs: ["HDMI"]))
        )
        XCTAssertEqual(explicit.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(explicit.monitor.observedProcessObjectIDs, [11])
    }

    func testAuthorizationSuccessCommitsRunningRuleAndProfile() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()

        fixture.coordinator.setProcessVolume(0.4, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.authorizationAttemptCount, 1)
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])
        XCTAssertEqual(fixture.engine.gains, [.init(volume: 0.4, isMuted: false)])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.4)
        )
        XCTAssertEqual(fixture.monitor.observationCalls, [
            .init(deviceIDs: [10, 20, 30], processObjectIDs: [11]),
        ])
    }

    func testPermissionDenialRequiresExplicitRetryBeforeCommittingProfile() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.engine.nextError = .permissionDenied(-1)

        fixture.coordinator.setProcessVolume(0.4, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.applyCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .permissionDenied)
        XCTAssertNil(fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier])

        fixture.engine.nextError = nil
        fixture.coordinator.retry(processObjectID: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.4)
        )
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testGenericNativeFailureIsTypedAndExplicitRetryCommits() async {
        let nativeError = ProcessTapEngineError.operationFailed(
            operation: .createTap,
            status: -50
        )
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.engine.nextError = nativeError

        fixture.coordinator.setProcessMuted(true, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .operationFailed(nativeError)
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].isMuted, false)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .failed)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.isMuted, true)
        XCTAssertNil(fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier])

        fixture.engine.nextError = nil
        fixture.coordinator.retry(processObjectID: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.engine.gains.last, .init(volume: 1, isMuted: true))
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(isMuted: true)
        )
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testProcessExitStopsExactObjectAndRetainsPersistedProfile() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.4, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()
        let profile = fixture.profile(volume: 0.4)

        fixture.processes = []
        fixture.emit([.processList])
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.stopCalls, [.init(processObjectID: 11, generation: 2)])
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [])
        XCTAssertEqual(fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier], profile)
        XCTAssertEqual(fixture.engine.applyCount, 1)
    }

    func testSamePIDObjectReplacementStopsOldObjectAndRestoresProfile() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.35, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        fixture.replaceProcess(
            oldObjectID: fixture.player.processObjectID,
            with: fixture.makePlayer(objectID: 22)
        )
        fixture.emit([.processList])
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.stopCalls, [.init(processObjectID: 11, generation: 2)])
        XCTAssertEqual(fixture.engine.plans.last?.processObjectID, 22)
        XCTAssertEqual(fixture.engine.plans.last?.generation, 1)
        XCTAssertEqual(fixture.engine.gains.last, .init(volume: 0.35, isMuted: false))
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [22])
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [22])
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.35)
        )
    }

    func testSampleRateChangeRebuildsOnlyAffectedRoute() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.5, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        fixture.emit([.device(10, .nominalSampleRate)])
        await fixture.finishPendingCommands()
        fixture.emit([.device(20, .nominalSampleRate)])
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.engine.plans.map(\.selectedTargetUIDs), [["BuiltIn"], ["BuiltIn"]])
        XCTAssertEqual(fixture.engine.gains, [
            .init(volume: 0.5, isMuted: false),
            .init(volume: 0.5, isMuted: false),
        ])
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.5)
        )
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testHALRestartCleansReobservesAndRestoresConfirmedRule() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.5, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()
        let eventOffset = fixture.lifecycle.events.count

        fixture.emit([.serviceRestarted])
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.stopAllCount, 1)
        XCTAssertEqual(fixture.engine.cleanupCount, 2)
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.engine.plans.map(\.selectedTargetUIDs), [["BuiltIn"], ["BuiltIn"]])
        XCTAssertEqual(
            Array(fixture.lifecycle.events.dropFirst(eventOffset)),
            [
                "engine.stopAll",
                "routes.read",
                "devices.read",
                "processes.read",
                "engine.cleanup",
                "engine.apply",
                "monitor.observe",
            ]
        )
        XCTAssertEqual(fixture.monitor.observationCalls.last?.deviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observationCalls.last?.processObjectIDs, [11])
        XCTAssertEqual(fixture.monitor.observationCalls.count, 2)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.5)
        )
    }

    func testStaleGenerationCannotOverwriteNewerRuleOrProfile() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        await fixture.engine.blockApplyReturn(1)

        fixture.coordinator.setProcessVolume(0.4, for: fixture.player.processObjectID)
        await fixture.engine.waitUntilApplyReturnCount(1)
        fixture.coordinator.setProcessVolume(0.6, for: fixture.player.processObjectID)
        await fixture.coordinator.testingWaitForProcessTask(fixture.player.processObjectID)
        await fixture.engine.resumeApplyReturns()
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.6)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.generation, 2)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.6)
        )
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testRunningRuleSliderBurstKeepsSessionIdentityAndUsesGainOnly() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.4, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()
        let session = fixture.coordinator.snapshot.processes[0].session
        await fixture.engine.blockGainUpdateCall(1)

        fixture.coordinator.setProcessVolume(0.5, for: fixture.player.processObjectID)
        await fixture.engine.waitUntilGainUpdateCount(1)
        fixture.coordinator.setProcessVolume(0.6, for: fixture.player.processObjectID)
        await fixture.engine.resumeGainUpdates()
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1])
        XCTAssertEqual(fixture.engine.gainUpdateCalls, [
            .init(processObjectID: 11, gain: .init(volume: 0.5, isMuted: false)),
            .init(processObjectID: 11, gain: .init(volume: 0.6, isMuted: false)),
        ])
        XCTAssertEqual(fixture.engine.stopCalls, [])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, session)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.6)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.6)
        )
    }

    func testPartialStartFailureLeavesOriginalRouteAndProfileConfirmed() async {
        let nativeError = ProcessTapEngineError.operationFailed(
            operation: .startDevice,
            status: -1
        )
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.5, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()
        fixture.engine.nextError = nativeError

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: fixture.player.processObjectID
        )
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.plans.map(\.selectedTargetUIDs), [["BuiltIn"], ["USB"]])
        XCTAssertEqual(fixture.engine.plans.map(\.generation), [1, 2])
        XCTAssertEqual(fixture.engine.gains, [
            .init(volume: 0.5, isMuted: false),
            .init(volume: 0.5, isMuted: false),
        ])
        XCTAssertEqual(fixture.engine.stopCalls, [])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].route, .followOriginal)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .failed)
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].pendingValues?.route,
            .explicit(targetDeviceUIDs: ["USB"])
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .operationFailed(nativeError))
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.5)
        )
        XCTAssertEqual(fixture.store.saveCount, 1)
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testPartialTeardownFailureRetriesBeforePublishingUnavailableState() async {
        let stopError = ProcessTapEngineError.operationFailed(
            operation: .destroyIOProc,
            status: -1
        )
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: fixture.player.processObjectID
        )
        await fixture.finishPendingCommands()
        fixture.engine.scriptedStopResults = [(.failed, stopError), (.idle, nil)]

        fixture.disconnect(uid: "USB")
        fixture.emit([.deviceList])
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.stopCalls, [.init(processObjectID: 11, generation: 2)])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .operationFailed(stopError))
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(route: .explicit(targetDeviceUIDs: ["USB"]))
        )

        fixture.coordinator.retry(processObjectID: fixture.player.processObjectID)
        await fixture.finishPendingCommands()

        XCTAssertEqual(fixture.engine.stopCalls, [
            .init(processObjectID: 11, generation: 2),
            .init(processObjectID: 11, generation: 3),
        ])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .targetUnavailable(["USB"])
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .idle)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(route: .explicit(targetDeviceUIDs: ["USB"]))
        )
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testPopoverCloseKeepsApplicationCoordinatorAndActiveRule() async throws {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.5, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()
        let delegate = AppDelegate(releasePageOpener: { _ in })
        delegate.testingConfigureDashboardPopoverFactory(
            preferencesController: fixture.preferences,
            audioControlCoordinator: fixture.coordinator
        )

        let firstPopover = delegate.testingResolveDashboardPopoverController()
        let firstModel = try XCTUnwrap(firstPopover.testingAudioDashboardModel)
        firstPopover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        let secondPopover = delegate.testingResolveDashboardPopoverController()
        let secondModel = try XCTUnwrap(secondPopover.testingAudioDashboardModel)

        XCTAssertFalse(firstPopover === secondPopover)
        XCTAssertFalse(firstModel === secondModel)
        XCTAssertTrue(firstModel.testingCoordinator === secondModel.testingCoordinator)
        XCTAssertTrue(secondModel.testingCoordinator === fixture.coordinator)
        XCTAssertEqual(fixture.engine.stopAllCount, 0)
        XCTAssertEqual(fixture.engine.applyCount, 1)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.5)
        )
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10, 20, 30])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testShutdownStopsMonitorBeforeEngineAndRetainsProfile() async {
        let fixture = AudioControlComponentFixture()
        await fixture.start()
        fixture.coordinator.setProcessVolume(0.5, for: fixture.player.processObjectID)
        await fixture.finishPendingCommands()
        let applyCount = fixture.engine.applyCount

        await fixture.coordinator.shutdown()

        XCTAssertEqual(fixture.monitor.stopCount, 1)
        XCTAssertEqual(fixture.engine.stopAllCount, 1)
        XCTAssertEqual(fixture.lifecycle.events.suffix(2), ["monitor.stop", "engine.stopAll"])
        XCTAssertEqual(fixture.engine.applyCount, applyCount)
        XCTAssertEqual(
            fixture.preferences.state.audioProcessProfiles[fixture.bundleIdentifier],
            fixture.profile(volume: 0.5)
        )
    }
}
