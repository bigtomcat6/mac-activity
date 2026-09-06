import CoreAudio
import Foundation
import XCTest

@testable import MacActivityApp
@testable import MacActivityCore

@MainActor
final class AudioSystemAccessCoordinatorTests: XCTestCase {
    func testAudioInputEntitlementIsEnabledForSystemAudioCapture() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Configuration/MacActivity.entitlements"))
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
    }

    func testPageActivationChecksOnceAtATimeThenRefreshesProcessesAndMonitoring() async {
        let checker = AudioSystemAccessCheckerFake()
        let firstCheckStarted = expectation(description: "first access check started")
        checker.observeCheckStarts { count in
            if count == 1 { firstCheckStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()
        XCTAssertEqual(checker.checkCount, 0)
        await checker.block()

        let first = Task { @MainActor in
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [firstCheckStarted], timeout: 1)
        let second = Task { @MainActor in
            await fixture.coordinator.checkSystemAudioAccess()
        }

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .checking)
        XCTAssertEqual(checker.checkCount, 1)

        await checker.resume()
        await first.value
        await second.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .available)
        XCTAssertEqual(checker.checkCount, 1)
        XCTAssertEqual(fixture.processProvider.callCount, 2)
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testAvailableAccessCheckRetriesInitialMonitorStartOnlyOncePerUserRequest() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.monitor.startError = FixtureError.writeFailed

        await fixture.coordinator.start()
        fixture.coordinator.setSystemAudioAccessPageVisible(true)
        await fixture.coordinator.checkSystemAudioAccess()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .available)
        XCTAssertEqual(fixture.monitor.startCount, 2)
        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)

        fixture.monitor.startError = nil
        await fixture.coordinator.checkSystemAudioAccess()

        XCTAssertEqual(fixture.monitor.startCount, 3)
        XCTAssertEqual(fixture.processProvider.callCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])

        fixture.processProvider.processes = []
        await fixture.emit([.processList])

        XCTAssertEqual(fixture.processProvider.callCount, 2)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
    }

    func testAvailableAccessCheckRecoversInitialMonitorObservationFailure() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.monitor.observationError = FixtureError.writeFailed

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.stopCount, 1)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
        XCTAssertEqual(fixture.processProvider.callCount, 1)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)

        fixture.monitor.observationError = nil
        fixture.coordinator.setSystemAudioAccessPageVisible(true)
        await fixture.coordinator.checkSystemAudioAccess()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .available)
        XCTAssertEqual(fixture.monitor.startCount, 2)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 1)
        XCTAssertEqual(fixture.processProvider.callCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])

        fixture.processProvider.processes = []
        await fixture.emit([.processList])

        XCTAssertEqual(fixture.processProvider.callCount, 3)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
    }

    func testUnavailableAccessResultsDoNotRetryFailedInitialization() async {
        let results: [AudioSystemAccessResult] = [
            .permissionRequired(kAudioDevicePermissionsError),
            .otherFailure(.unsupported),
        ]

        for result in results {
            let fixture = CoordinatorFixture(
                availability: .supported,
                systemAudioAccessChecker: AudioSystemAccessCheckerFake(results: [result])
            )
            fixture.monitor.startError = FixtureError.writeFailed

            await fixture.coordinator.start()
            fixture.monitor.startError = nil
            await fixture.coordinator.checkSystemAudioAccess()

            XCTAssertEqual(fixture.monitor.startCount, 1)
            XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        }
    }

    func testPermissionAndNonPermissionResultsRemainDistinct() async {
        let permissionChecker = AudioSystemAccessCheckerFake(results: [
            .permissionRequired(kAudioDevicePermissionsError),
        ])
        let permissionFixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: permissionChecker
        )
        await permissionFixture.coordinator.start()
        await permissionFixture.coordinator.checkSystemAudioAccess()

        XCTAssertEqual(
            permissionFixture.coordinator.snapshot.systemAudioAccess,
            .permissionRequired
        )

        let error = AudioHALError(
            operation: .startDevice,
            objectID: 702,
            address: nil,
            reason: .status(-701)
        )
        let failureChecker = AudioSystemAccessCheckerFake(results: [
            .otherFailure(.operationFailed(error)),
        ])
        let failureFixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: failureChecker
        )
        await failureFixture.coordinator.start()
        await failureFixture.coordinator.checkSystemAudioAccess()

        XCTAssertEqual(
            failureFixture.coordinator.snapshot.systemAudioAccess,
            .otherFailure(.operationFailed(error))
        )
    }

    func testRetryOrSettingsReturnStartsANewCheckAfterPermissionIsRequired() async {
        let checker = AudioSystemAccessCheckerFake(results: [
            .permissionRequired(kAudioDevicePermissionsError),
            .available,
        ])
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()

        await fixture.coordinator.checkSystemAudioAccess()
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .permissionRequired)

        await fixture.coordinator.checkSystemAudioAccess()
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .available)
        XCTAssertEqual(checker.checkCount, 2)
    }

    func testVisibleAudioPageRechecksAccessAfterAServiceRestart() async {
        let checker = AudioSystemAccessCheckerFake(results: [
            .available,
            .permissionRequired(kAudioDevicePermissionsError),
        ])
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()
        fixture.coordinator.setSystemAudioAccessPageVisible(true)
        await fixture.coordinator.checkSystemAudioAccess()

        await fixture.coordinator.testingHandle([.serviceRestarted])

        XCTAssertEqual(checker.checkCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .permissionRequired)
    }

    func testHiddenAudioPageDefersServiceRestartAccessCheckUntilItsNextVisit() async {
        let checker = AudioSystemAccessCheckerFake(results: [.available, .available])
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()
        fixture.coordinator.setSystemAudioAccessPageVisible(false)
        await fixture.coordinator.checkSystemAudioAccess()

        await fixture.coordinator.testingHandle([.serviceRestarted])

        XCTAssertEqual(checker.checkCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .notChecked)

        fixture.coordinator.setSystemAudioAccessPageVisible(true)
        await fixture.coordinator.checkSystemAudioAccess()

        XCTAssertEqual(checker.checkCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .available)
    }

    func testServiceRestartWaitsForAnInFlightCheckBeforePublishingItsReplacement() async {
        let checker = AudioSystemAccessCheckerFake(results: [
            .available,
            .permissionRequired(kAudioDevicePermissionsError),
        ])
        let firstCheckStarted = expectation(description: "first access check started")
        checker.observeCheckStarts { count in
            if count == 1 { firstCheckStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()
        fixture.coordinator.setSystemAudioAccessPageVisible(true)
        await checker.block()

        let checking = Task { @MainActor in
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [firstCheckStarted], timeout: 1)
        let restarting = Task { @MainActor in
            await fixture.coordinator.testingHandle([.serviceRestarted])
        }
        await Task.yield()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .notChecked)
        XCTAssertEqual(checker.checkCount, 1)

        await checker.resume()
        await checking.value
        await restarting.value

        XCTAssertEqual(checker.checkCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .permissionRequired)
    }

    func testUnsupportedAudioPageDoesNotCallTheAccessChecker() async {
        let checker = AudioSystemAccessCheckerFake()
        let fixture = CoordinatorFixture(
            availability: .unsupported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()

        await fixture.coordinator.checkSystemAudioAccess()

        XCTAssertEqual(checker.checkCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .notChecked)
    }

    func testNoPlaybackAfterSuccessfulCheckShowsTheProcessEmptyState() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.processProvider.processes = []
        await fixture.coordinator.start()

        await fixture.coordinator.checkSystemAudioAccess()

        let presentation = AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        )
        XCTAssertNotNil(presentation.processSection)
        XCTAssertTrue(presentation.processSection?.processes.isEmpty == true)
        XCTAssertNil(presentation.processSection?.runtimeErrorText)
    }

    func testProcessPermissionFailureDuringControlApplyWaitsForTheOldProbeBeforeRetrying() async {
        let checker = SingleFlightAudioSystemAccessCheckerFake(results: [
            .available,
            .permissionRequired(kAudioDevicePermissionsError),
        ])
        let firstProbeStarted = expectation(description: "old access probe started")
        let replacementProbeStarted = expectation(description: "fresh access probe started")
        checker.observeProbeStarts { probe in
            if probe == 1 {
                firstProbeStarted.fulfill()
            } else if probe == 2 {
                replacementProbeStarted.fulfill()
            }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()
        await checker.blockProbe(1)
        await checker.blockProbe(2)

        let checking = Task { @MainActor in
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [firstProbeStarted], timeout: 1)
        fixture.engine.nextError = .permissionDenied(kAudioDevicePermissionsError)

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .permissionRequired)

        let firstRetryEntered = expectation(description: "first retry invoked")
        let firstRetry = Task { @MainActor in
            firstRetryEntered.fulfill()
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [firstRetryEntered], timeout: 1)
        let secondRetryEntered = expectation(description: "second retry invoked")
        let secondRetry = Task { @MainActor in
            secondRetryEntered.fulfill()
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [secondRetryEntered], timeout: 1)

        await checker.resumeProbe(1)
        await fulfillment(of: [replacementProbeStarted], timeout: 1)
        XCTAssertEqual(checker.probeCount, 2)

        await checker.resumeProbe(2)
        await checking.value
        await firstRetry.value
        await secondRetry.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .permissionRequired)
        XCTAssertEqual(checker.probeCount, 2)
    }

    func testProcessPermissionFailureFromEngineSnapshotRetriesWithAFreshAccessProbe() async {
        let checker = SingleFlightAudioSystemAccessCheckerFake(results: [.available, .available])
        let firstProbeStarted = expectation(description: "old access probe started")
        checker.observeProbeStarts { probe in
            if probe == 1 { firstProbeStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()
        await checker.blockProbe(1)

        let checking = Task { @MainActor in
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [firstProbeStarted], timeout: 1)
        await fixture.emitEngine(.init(
            processObjectID: 11,
            generation: 0,
            state: .failed,
            error: .permissionDenied(kAudioDevicePermissionsError),
            commandSequence: 1,
            emissionOrdinal: 1
        ))

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .permissionRequired)

        let retryEntered = expectation(description: "retry invoked")
        let retry = Task { @MainActor in
            retryEntered.fulfill()
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [retryEntered], timeout: 1)

        await checker.resumeProbe(1)
        await checking.value
        await retry.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .available)
        XCTAssertEqual(checker.probeCount, 2)
    }

    func testShutdownIgnoresAStaleAccessCompletion() async {
        let checker = AudioSystemAccessCheckerFake()
        let firstCheckStarted = expectation(description: "first access check started")
        checker.observeCheckStarts { count in
            if count == 1 { firstCheckStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAccessChecker: checker
        )
        await fixture.coordinator.start()
        await checker.block()

        let checking = Task { @MainActor in
            await fixture.coordinator.checkSystemAudioAccess()
        }
        await fulfillment(of: [firstCheckStarted], timeout: 1)
        let shutdown = Task { @MainActor in
            await fixture.coordinator.shutdown()
        }
        await checker.resume()
        await checking.value
        await shutdown.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .checking)
        XCTAssertEqual(checker.shutdownCount, 1)
        XCTAssertEqual(checker.drainCount, 1)
    }
}
