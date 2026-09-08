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

    func testLifecycleRefreshesNeverStartTheCallbackRequester() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )

        await fixture.coordinator.start()
        await fixture.coordinator.refreshSystemAudioAuthorization()
        await fixture.coordinator.testingHandle([.serviceRestarted])

        XCTAssertGreaterThanOrEqual(reader.readCount, 3)
        XCTAssertEqual(requester.requestCount, 0)
    }

    func testUnauthorizedStatusesHideProcessRowsAndDoNotPrepareRuntime() async {
        let cases: [(AudioSystemAuthorizationStatus, AudioSystemAccessState)] = [
            (.denied, .denied),
            (.notDetermined, .notDetermined),
            (.unavailable, .unavailable),
        ]

        for (status, expectedState) in cases {
            let fixture = CoordinatorFixture(
                availability: .supported,
                systemAudioAuthorizationReader: AudioSystemAuthorizationReaderFake(statuses: [status])
            )

            await fixture.coordinator.start()

            XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, expectedState)
            XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
            XCTAssertFalse(fixture.coordinator.snapshot.processControlsAreVisible)
            XCTAssertEqual(fixture.processProvider.callCount, 0)
            XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
        }
    }

    func testSavedProfileDoesNotStartATapWithoutCurrentAuthorization() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.4
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            systemAudioAuthorizationReader: AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
    }

    func testAuthorizedStatusShowsApplicationRowsWithoutACallbackRequest() async {
        let requester = AudioSystemAuthorizationRequesterFake()
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: AudioSystemAuthorizationReaderFake(statuses: [.authorized]),
            systemAudioAuthorizationRequester: requester
        )

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
        XCTAssertEqual(requester.requestCount, 0)
    }

    func testAuthorizedNoPlaybackShowsTheProcessEmptyState() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: AudioSystemAuthorizationReaderFake(statuses: [.authorized])
        )
        fixture.processProvider.processes = []

        await fixture.coordinator.start()

        let presentation = AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        )
        XCTAssertNotNil(presentation.processSection)
        XCTAssertTrue(presentation.processSection?.processes.isEmpty == true)
        XCTAssertNil(presentation.permissionGate)
    }

    func testPersistentAuthorizedPermissionFailureDoesNotAutomaticallyRestoreSavedProfile() async throws {
        let profile = AudioProcessProfile(bundleIdentifier: "com.example.music", volume: 0.4)
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.authorized])
        let requester = AudioSystemAuthorizationRequesterFake()
        let engine = EngineFake()
        engine.nextError = .permissionDenied(-1)
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            engine: engine,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        let firstApply = expectation(description: "initial saved-profile apply")
        let repeatedApply = expectation(description: "automatic saved-profile reapply")
        repeatedApply.isInverted = true
        let startupFinished = expectation(description: "startup finishes after cleanup")
        engine.observeApplyStarts { count in
            if count == 1 {
                firstApply.fulfill()
            } else if count == 2 {
                repeatedApply.fulfill()
            }
        }

        let startup = Task { @MainActor in
            await fixture.coordinator.start()
            startupFinished.fulfill()
        }
        await fulfillment(of: [firstApply], timeout: 1)
        await fulfillment(of: [repeatedApply], timeout: 0.2)

        let applyCount = engine.applyCount
        let readCount = reader.readCount
        let requesterCount = requester.requestCount
        let failedRow = fixture.coordinator.snapshot.processes.first
        await fixture.coordinator.shutdown()
        await fulfillment(of: [startupFinished], timeout: 1)
        await startup.value

        XCTAssertEqual(applyCount, 1)
        XCTAssertLessThanOrEqual(readCount, 4)
        XCTAssertEqual(requesterCount, 0)
        let row = try XCTUnwrap(failedRow)
        XCTAssertEqual(row.error, .permissionDenied)
        XCTAssertEqual(row.pendingValues?.volume, profile.volume)
        XCTAssertNotNil(AudioProcessRowPresentation(row).retryAccessibility)
    }

    func testGenuineReauthorizationRestoresSavedProfileAfterPermissionFailure() async throws {
        let profile = AudioProcessProfile(bundleIdentifier: "com.example.music", volume: 0.4)
        let reader = AudioSystemAuthorizationReaderFake(statuses: [
            .authorized,
            .authorized,
            .authorized,
            .denied,
            .authorized,
        ])
        let requester = AudioSystemAuthorizationRequesterFake()
        let engine = EngineFake()
        engine.nextError = .permissionDenied(-1)
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            engine: engine,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )

        await fixture.coordinator.start()
        await fixture.coordinator.refreshSystemAudioAuthorization()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .denied)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)

        engine.nextError = nil
        await fixture.coordinator.refreshSystemAudioAuthorization()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
        XCTAssertEqual(engine.applyCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.first?.volume, profile.volume)
        XCTAssertNil(fixture.coordinator.snapshot.processes.first?.error)
        XCTAssertEqual(requester.requestCount, 0)
        await fixture.coordinator.shutdown()
    }

    func testAuthorizedSilentRefreshKeepsRowsVisibleUntilDeniedPreflightCompletes() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [
            .authorized,
            .authorized,
            .authorized,
            .denied,
        ])
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader
        )
        let refreshStarted = expectation(description: "blocked silent refresh started")
        reader.observeReadStarts { count in
            if count == 4 {
                refreshStarted.fulfill()
            }
        }

        await fixture.coordinator.start()
        await reader.block()
        let refresh = Task { @MainActor in
            await fixture.coordinator.refreshSystemAudioAuthorization()
        }
        await fulfillment(of: [refreshStarted], timeout: 1)

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
        XCTAssertFalse(fixture.coordinator.snapshot.processes.isEmpty)
        let authorizedPresentation = AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        )
        XCTAssertNotNil(authorizedPresentation.processSection)
        XCTAssertNil(authorizedPresentation.permissionGate)

        await reader.resume()
        await refresh.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .denied)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        let deniedPresentation = AudioDashboardPresentation(
            snapshot: fixture.coordinator.snapshot,
            supportsProcessControls: fixture.coordinator.supportsProcessControls
        )
        XCTAssertNil(deniedPresentation.processSection)
        XCTAssertEqual(deniedPresentation.permissionGate, .denied)
        await fixture.coordinator.shutdown()
    }

    func testExplicitGrantWaitsForAuthorizedCallbackAndRestoresSavedProfileWithoutStalePreflight() async {
        let profile = AudioProcessProfile(bundleIdentifier: "com.example.music", volume: 0.4)
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }

        await fixture.coordinator.start()
        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .requesting)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(fixture.engine.applyCount, 0)

        requester.complete(.authorized)
        await request.value
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes.first?.volume, profile.volume)
        XCTAssertEqual(fixture.engine.applyCount, 1)
        XCTAssertEqual(reader.readCount, 1)
    }

    func testExplicitGrantCommitsDeniedCallbackWithoutRereadingPreflight() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }

        await fixture.coordinator.start()
        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        requester.complete(.denied)
        await request.value

        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .denied)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(
            AudioDashboardPresentation(
                snapshot: fixture.coordinator.snapshot,
                supportsProcessControls: true
            ).permissionGate?.action,
            .openSettings
        )
    }

    func testExplicitGrantReportsUnavailableCallbackWithoutInventingAuthorization() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }

        await fixture.coordinator.start()
        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        requester.complete(.unavailable)
        await request.value

        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .unavailable)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(
            AudioDashboardPresentation(
                snapshot: fixture.coordinator.snapshot,
                supportsProcessControls: true
            ).permissionGate?.action,
            .refresh
        )
    }

    func testExplicitGrantIsSingleFlight() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }
        await fixture.coordinator.start()

        let first = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        let second = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .requesting)
        XCTAssertEqual(requester.requestCount, 1)

        requester.complete(.authorized)
        await first.value
        await second.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
        XCTAssertEqual(requester.requestCount, 1)
    }

    func testFocusRefreshDuringExplicitGrantJoinsCallbackDecisionWithoutAnotherRequest() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }
        await fixture.coordinator.start()

        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        let focusRefresh = Task { @MainActor in
            await fixture.coordinator.refreshSystemAudioAuthorization()
        }
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .requesting)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(requester.requestCount, 1)

        requester.complete(.authorized)
        await request.value
        await focusRefresh.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(requester.requestCount, 1)
    }

    func testAuthorizedCallbackIgnoresLaggingFocusPreflightsUntilConfirmed() async {
        let cases: [(
            AudioSystemAuthorizationStatus,
            AudioSystemAccessState,
            AudioSystemAccessPermissionGatePresentation.Action
        )] = [
            (.denied, .denied, .openSettings),
            (.unavailable, .unavailable, .refresh),
            (.notDetermined, .notDetermined, .requestAccess),
        ]

        for (laterStatus, expectedState, expectedAction) in cases {
            let reader = AudioSystemAuthorizationReaderFake(statuses: [
                .notDetermined,
                .notDetermined,
                .notDetermined,
                .notDetermined,
                .authorized,
                laterStatus,
            ])
            let requester = AudioSystemAuthorizationRequesterFake()
            let requestStarted = expectation(description: "callback request started")
            requester.observeRequestStarts { count in
                if count == 1 { requestStarted.fulfill() }
            }
            let fixture = CoordinatorFixture(
                availability: .supported,
                systemAudioAuthorizationReader: reader,
                systemAudioAuthorizationRequester: requester
            )
            let model = AudioDashboardModel(coordinator: fixture.coordinator)
            defer {
                requester.complete(.unavailable)
                Task { @MainActor in await fixture.coordinator.shutdown() }
            }

            await fixture.coordinator.start()
            await model.audioPageActivated()
            let request = Task { @MainActor in
                await model.requestSystemAudioAccess()
            }
            await fulfillment(of: [requestStarted], timeout: 1)
            requester.complete(.authorized)
            await request.value
            await fixture.coordinator.testingWaitUntilIdle()

            await model.applicationDidBecomeActive()
            XCTAssertEqual(model.snapshot.systemAudioAccess, .authorized)
            XCTAssertEqual(model.snapshot.processes.map(\.id), [11])
            XCTAssertEqual(requester.requestCount, 1)

            await model.applicationDidBecomeActive()
            XCTAssertEqual(model.snapshot.systemAudioAccess, .authorized)
            XCTAssertEqual(model.snapshot.processes.map(\.id), [11])
            XCTAssertEqual(reader.readCount, 4)
            XCTAssertEqual(requester.requestCount, 1)

            await model.applicationDidBecomeActive()
            XCTAssertEqual(model.snapshot.systemAudioAccess, .authorized)
            XCTAssertEqual(model.snapshot.processes.map(\.id), [11])
            XCTAssertEqual(reader.readCount, 5)

            await model.applicationDidBecomeActive()
            XCTAssertEqual(model.snapshot.systemAudioAccess, expectedState)
            XCTAssertTrue(model.snapshot.processes.isEmpty)
            XCTAssertEqual(
                AudioDashboardPresentation(
                    snapshot: model.snapshot,
                    supportsProcessControls: true
                ).permissionGate?.action,
                expectedAction
            )
            XCTAssertEqual(reader.readCount, 6)
            XCTAssertEqual(requester.requestCount, 1)
            await fixture.coordinator.shutdown()
        }
    }

    func testDeniedCallbackIgnoresLaggingFocusPreflightUntilConfirmed() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [
            .notDetermined,
            .notDetermined,
            .notDetermined,
            .authorized,
        ])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        let model = AudioDashboardModel(coordinator: fixture.coordinator)
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }

        await fixture.coordinator.start()
        await model.audioPageActivated()
        let request = Task { @MainActor in
            await model.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        requester.complete(.denied)
        await request.value

        await model.applicationDidBecomeActive()
        XCTAssertEqual(model.snapshot.systemAudioAccess, .denied)
        XCTAssertTrue(model.snapshot.processes.isEmpty)
        XCTAssertEqual(
            AudioDashboardPresentation(
                snapshot: model.snapshot,
                supportsProcessControls: true
            ).permissionGate?.action,
            .openSettings
        )
        XCTAssertEqual(requester.requestCount, 1)

        await model.applicationDidBecomeActive()
        XCTAssertEqual(model.snapshot.systemAudioAccess, .authorized)
        XCTAssertEqual(model.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(reader.readCount, 4)
        XCTAssertEqual(requester.requestCount, 1)
        await fixture.coordinator.shutdown()
    }

    func testEnginePermissionFailureClearsCallbackConfirmationFence() async {
        let profile = AudioProcessProfile(bundleIdentifier: "com.example.music", volume: 0.4)
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined, .notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let engine = EngineFake()
        engine.nextError = .permissionDenied(-1)
        let requestStarted = expectation(description: "callback request started")
        let validationStarted = expectation(description: "permission failure validation started")
        let requestStartedSignal = AuthorizationExpectationSignal(requestStarted)
        let validationStartedSignal = AuthorizationExpectationSignal(validationStarted)
        requester.observeRequestStarts { count in
            if count == 1 { requestStartedSignal.fulfill() }
        }
        reader.observeReadStarts { count in
            if count == 2 { validationStartedSignal.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            engine: engine,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }

        await fixture.coordinator.start()
        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        requester.complete(.authorized)
        await request.value
        await fulfillment(of: [validationStarted], timeout: 1)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .notDetermined)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(requester.requestCount, 1)
        await fixture.coordinator.shutdown()
    }

    func testExplicitGrantSupersedesAnInFlightPassiveRefresh() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [
            .notDetermined,
            .denied,
        ])
        let requester = AudioSystemAuthorizationRequesterFake()
        let passiveReadStarted = expectation(description: "passive read started")
        let activeRequestStarted = expectation(description: "callback request started")
        reader.observeReadStarts { count in
            if count == 2 { passiveReadStarted.fulfill() }
        }
        requester.observeRequestStarts { count in
            if count == 1 { activeRequestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in
                await reader.resume()
                await fixture.coordinator.shutdown()
            }
        }
        await fixture.coordinator.start()
        await reader.block()

        let passiveRefresh = Task { @MainActor in
            await fixture.coordinator.refreshSystemAudioAuthorization()
        }
        await fulfillment(of: [passiveReadStarted], timeout: 1)
        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [activeRequestStarted], timeout: 1)

        requester.complete(.authorized)
        await reader.resume()
        await passiveRefresh.value
        await request.value

        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
    }

    func testLaterIndependentPassiveStatusesOverrideAfterConfirmingCallbackDecision() async {
        let cases: [(AudioSystemAuthorizationStatus, AudioSystemAccessState)] = [
            (.denied, .denied),
            (.notDetermined, .notDetermined),
            (.unavailable, .unavailable),
        ]

        for (passiveStatus, expectedState) in cases {
            let reader = AudioSystemAuthorizationReaderFake(statuses: [
                .notDetermined,
                .authorized,
                passiveStatus,
            ])
            let requester = AudioSystemAuthorizationRequesterFake()
            let requestStarted = expectation(description: "callback request started")
            requester.observeRequestStarts { count in
                if count == 1 { requestStarted.fulfill() }
            }
            let fixture = CoordinatorFixture(
                availability: .supported,
                systemAudioAuthorizationReader: reader,
                systemAudioAuthorizationRequester: requester
            )
            defer {
                requester.complete(.unavailable)
                Task { @MainActor in await fixture.coordinator.shutdown() }
            }
            await fixture.coordinator.start()

            let request = Task { @MainActor in
                await fixture.coordinator.requestSystemAudioAccess()
            }
            await fulfillment(of: [requestStarted], timeout: 1)
            requester.complete(.authorized)
            await request.value

            XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
            XCTAssertEqual(reader.readCount, 1)

            await fixture.coordinator.refreshSystemAudioAuthorization()

            XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .authorized)
            XCTAssertEqual(reader.readCount, 2)

            await fixture.coordinator.refreshSystemAudioAuthorization()

            XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, expectedState)
            XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
            XCTAssertEqual(reader.readCount, 3)
            await fixture.coordinator.shutdown()
        }
    }

    func testServiceRestartDiscardsPendingCallbackBeforeItsLateResult() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in await fixture.coordinator.shutdown() }
        }
        await fixture.coordinator.start()
        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)

        let restart = Task { @MainActor in
            await fixture.coordinator.testingHandle([.serviceRestarted])
        }
        await restart.value

        XCTAssertEqual(requester.shutdownCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .notDetermined)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)

        requester.complete(.authorized)
        await request.value
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(requester.callbackCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .notDetermined)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
    }

    func testServiceRestartQueuesRegrantUntilTheOldNativeCallbackDrains() async {
        let cases: [(Bool, AudioSystemAccessState)] = [
            (false, .denied),
            (true, .authorized),
        ]

        for (freshDecision, expectedState) in cases {
            let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined, .notDetermined])
            let rawRequest = RetainedRawAuthorizationRequestRecorder()
            let firstNativeRequestStarted = expectation(description: "first native request started")
            let freshNativeRequestStarted = expectation(description: "fresh native request started")
            let firstNativeRequestStartedSignal = AuthorizationExpectationSignal(
                firstNativeRequestStarted
            )
            let freshNativeRequestStartedSignal = AuthorizationExpectationSignal(
                freshNativeRequestStarted
            )
            let regrantQueued = expectation(description: "regrant queued behind abandoned request")
            let regrantQueuedSignal = AuthorizationExpectationSignal(regrantQueued)
            rawRequest.observeStarts { count in
                if count == 1 {
                    firstNativeRequestStartedSignal.fulfill()
                } else if count == 2 {
                    freshNativeRequestStartedSignal.fulfill()
                }
            }
            let requester = AudioSystemAuthorizationRequester(
                availability: .supported,
                rawRequest: { callback in rawRequest.start(callback) }
            )
            await requester.testingObserveQueuedWaiterRegistration {
                regrantQueuedSignal.fulfill()
            }
            let fixture = CoordinatorFixture(
                availability: .supported,
                systemAudioAuthorizationReader: reader,
                systemAudioAuthorizationRequester: requester
            )
            defer { rawRequest.completeAll(false) }

            await fixture.coordinator.start()
            let firstGrant = Task { @MainActor in
                await fixture.coordinator.requestSystemAudioAccess()
            }
            await fulfillment(of: [firstNativeRequestStarted], timeout: 1)

            await fixture.coordinator.testingHandle([.serviceRestarted])
            await firstGrant.value
            XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .notDetermined)

            let regrant = Task { @MainActor in
                await fixture.coordinator.requestSystemAudioAccess()
            }
            await fulfillment(of: [regrantQueued], timeout: 1)
            XCTAssertEqual(rawRequest.callCount, 1)

            rawRequest.complete(true, request: 0)
            await fulfillment(of: [freshNativeRequestStarted], timeout: 1)
            XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .requesting)
            XCTAssertEqual(rawRequest.callCount, 2)

            rawRequest.complete(freshDecision, request: 1)
            await regrant.value
            await fixture.coordinator.testingWaitUntilIdle()

            XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, expectedState)
            XCTAssertEqual(reader.readCount, 2)
            if expectedState == .authorized {
                XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
            } else {
                XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
            }
            await fixture.coordinator.shutdown()
        }
    }

    func testIndependentPassiveRevocationRunsWhileCallbackRestorationIsBlocked() async {
        let profile = AudioProcessProfile(bundleIdentifier: "com.example.music", volume: 0.4)
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined, .denied])
        let requester = AudioSystemAuthorizationRequesterFake()
        let engine = EngineFake()
        let requestStarted = expectation(description: "callback request started")
        let restorationStarted = expectation(description: "saved-profile restoration started")
        let passiveReadStarted = expectation(description: "independent passive read started")
        let requestStartedSignal = AuthorizationExpectationSignal(requestStarted)
        let restorationStartedSignal = AuthorizationExpectationSignal(restorationStarted)
        let passiveReadStartedSignal = AuthorizationExpectationSignal(passiveReadStarted)
        requester.observeRequestStarts { count in
            if count == 1 { requestStartedSignal.fulfill() }
        }
        engine.observeApplyStarts { count in
            if count == 1 { restorationStartedSignal.fulfill() }
        }
        reader.observeReadStarts { count in
            if count == 2 { passiveReadStartedSignal.fulfill() }
        }
        await engine.blockApplyCall(1)
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile],
            engine: engine,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        defer {
            requester.complete(.unavailable)
            Task { @MainActor in
                await engine.resumeApplies()
                await fixture.coordinator.shutdown()
            }
        }

        await fixture.coordinator.start()
        let grant = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        requester.complete(.authorized)
        await fulfillment(of: [restorationStarted], timeout: 1)

        let passiveRefresh = Task { @MainActor in
            await fixture.coordinator.refreshSystemAudioAuthorization()
        }
        await fulfillment(of: [passiveReadStarted], timeout: 1)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .denied)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(
            AudioDashboardPresentation(
                snapshot: fixture.coordinator.snapshot,
                supportsProcessControls: true
            ).permissionGate?.action,
            .openSettings
        )

        await engine.resumeApplies()
        await passiveRefresh.value
        await grant.value
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .denied)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        await fixture.coordinator.shutdown()
    }

    func testServiceRestartUsesPreflightAndHidesRowsWhenAuthorizationIsRevoked() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [
            .authorized,
            .authorized,
            .denied,
        ])
        let requester = AudioSystemAuthorizationRequesterFake()
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        await fixture.coordinator.start()

        await fixture.coordinator.testingHandle([.serviceRestarted])

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .denied)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(requester.requestCount, 0)
    }

    func testUnsupportedSystemsNeverReadAuthorizationOrStartProcessRuntime() async {
        let reader = AudioSystemAuthorizationReaderFake()
        let requester = AudioSystemAuthorizationRequesterFake()
        let fixture = CoordinatorFixture(
            availability: .unsupported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )

        await fixture.coordinator.start()
        await fixture.coordinator.refreshSystemAudioAuthorization()
        await fixture.coordinator.requestSystemAudioAccess()

        XCTAssertEqual(reader.readCount, 0)
        XCTAssertEqual(requester.requestCount, 0)
        XCTAssertEqual(fixture.engine.prepareRuntimeCount, 0)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
    }

    func testShutdownIgnoresAStalePassiveRefreshCompletion() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined, .authorized])
        let refreshStarted = expectation(description: "passive refresh started")
        reader.observeReadStarts { count in
            if count == 2 { refreshStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader
        )
        await fixture.coordinator.start()
        await reader.block()

        let refresh = Task { @MainActor in
            await fixture.coordinator.refreshSystemAudioAuthorization()
        }
        await fulfillment(of: [refreshStarted], timeout: 1)
        let shutdown = Task { @MainActor in
            await fixture.coordinator.shutdown()
        }

        await reader.resume()
        await refresh.value
        await shutdown.value

        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .checking)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
    }

    func testShutdownDiscardsPendingCallbackAndIgnoresItsLateResult() async {
        let reader = AudioSystemAuthorizationReaderFake(statuses: [.notDetermined])
        let requester = AudioSystemAuthorizationRequesterFake()
        let requestStarted = expectation(description: "callback request started")
        requester.observeRequestStarts { count in
            if count == 1 { requestStarted.fulfill() }
        }
        let fixture = CoordinatorFixture(
            availability: .supported,
            systemAudioAuthorizationReader: reader,
            systemAudioAuthorizationRequester: requester
        )
        await fixture.coordinator.start()

        let request = Task { @MainActor in
            await fixture.coordinator.requestSystemAudioAccess()
        }
        await fulfillment(of: [requestStarted], timeout: 1)
        let shutdown = Task { @MainActor in
            await fixture.coordinator.shutdown()
        }

        await request.value
        await shutdown.value
        requester.complete(.authorized)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(requester.callbackCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.systemAudioAccess, .requesting)
        XCTAssertEqual(requester.shutdownCount, 1)
        XCTAssertTrue(fixture.coordinator.snapshot.processes.isEmpty)
        XCTAssertEqual(reader.readCount, 1)
    }
}

private final class RetainedRawAuthorizationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Bool) -> Void] = []
    private var requests = 0
    private var startObserver: (@Sendable (Int) -> Void)?

    var callCount: Int {
        lock.withLock { requests }
    }

    func observeStarts(_ observer: @escaping @Sendable (Int) -> Void) {
        lock.withLock { startObserver = observer }
    }

    func start(
        _ callback: @escaping @Sendable (Bool) -> Void
    ) -> AudioSystemAuthorizationRequestLease? {
        let start = lock.withLock { () -> (count: Int, observer: (@Sendable (Int) -> Void)?) in
            requests += 1
            callbacks.append(callback)
            return (requests, startObserver)
        }
        start.observer?(start.count)
        return .init(retaining: NSObject())
    }

    func complete(_ granted: Bool, request: Int) {
        let callback = lock.withLock {
            callbacks.indices.contains(request) ? callbacks[request] : nil
        }
        callback?(granted)
    }

    func completeAll(_ granted: Bool) {
        let callbacks = lock.withLock { self.callbacks }
        callbacks.forEach { $0(granted) }
    }
}

private final class AuthorizationExpectationSignal: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}
