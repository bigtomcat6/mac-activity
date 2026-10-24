import XCTest
@testable import MacActivityBatteryControl

final class UnavailableBatteryCareServiceTests: XCTestCase {
    func testUnavailableServiceNeverReportsAppliedOrReleased() async throws {
        let service = UnavailableBatteryCareService()
        let intents: [BatteryCareIntent] = [.setManagement(true), .startDischarge, .startFullCharge,
            .retryRegular, .stopDischarge, .cancelFullCharge, .setManagement(false),
            .releaseOwnedControls(reason: .shutdown)]
        for (index, intent) in intents.enumerated() {
            let reply = await service.send(.init(requestID: UUID(), generation: UInt64(index + 1), intent: intent))
            XCTAssertNotEqual(reply.outcome, .accepted)
            let value = await service.snapshot()
            XCTAssertFalse(value.settings.isEnabled)
            XCTAssertEqual(value.readback, .unknown)
            XCTAssertEqual(value.physicalObservation, .unknown)
            XCTAssertEqual(value.completion, .unknown)
            XCTAssertEqual(value.recoveryStatus, .unknown)
            XCTAssertNil(value.sample)
            XCTAssertNil(value.safetyLimits)
            XCTAssertTrue(value.capabilities.values.allSatisfy { $0 == .unverified })
        }
        let reply = await service.handleLifecycle(.quit, generation: 9)
        XCTAssertEqual(reply.outcome, .outcomeUnknown)
    }

    func testOfflineLimitIsOnlyAnAcceptedIntentAndUpdatesCarryRealVersions() async {
        let service = UnavailableBatteryCareService()
        var updates = await service.updates().makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial?.settings, .default)
        let command = BatteryCareCommand(requestID: UUID(), generation: 7, intent: .setLimit(73))
        let reply = await service.send(command)
        XCTAssertEqual(reply.requestID, command.requestID)
        XCTAssertEqual(reply.outcome, .accepted)
        let changed = await updates.next()
        XCTAssertEqual(changed?.settings.limit, 73)
        XCTAssertEqual(changed?.generation, 7)
        XCTAssertEqual(changed?.revision, reply.revision)
        let stale = await service.send(.init(requestID: UUID(), generation: 6, intent: .setLimit(90)))
        XCTAssertEqual(stale.outcome, .rejected(reason: "staleGeneration"))
        let invalid = await service.send(.init(requestID: UUID(), generation: 8, intent: .setLimit(49)))
        XCTAssertEqual(invalid.outcome, .rejected(reason: "invalidLimit"))
        let final = await service.snapshot()
        XCTAssertEqual(final.settings.limit, 73)
    }
}
