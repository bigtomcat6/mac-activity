import Foundation
import XCTest
import MacActivityBatteryControl

final class BatteryCareModelsTests: XCTestCase {
    func testLimitsAcceptEveryInteger50Through100() throws {
        for limit in 50...100 {
            let settings = try BatteryCareSettings(limit: limit)
            XCTAssertEqual(settings.limit, limit)
            XCTAssertFalse(settings.isEnabled)
            XCTAssertEqual(try JSONDecoder().decode(BatteryCareSettings.self, from: JSONEncoder().encode(settings)), settings)
        }
        XCTAssertEqual(BatteryCareSettings.default.limit, 80)
        XCTAssertFalse(BatteryCareSettings.default.isEnabled)
    }

    func testInvalidSettingsAreRejectedWithoutClamping() {
        for limit in [Int.min, 49, 101, Int.max] {
            XCTAssertThrowsError(try BatteryCareSettings(limit: limit))
        }
        for json in [
            #"{"isEnabled":true,"limit":49}"#, #"{"isEnabled":false,"limit":101}"#,
            #"{"isEnabled":false,"limit":80.5}"#, #"{"isEnabled":false,"limit":"80"}"#,
            #"{"isEnabled":"false","limit":80}"#, #"{"limit":80}"#,
            #"{"isEnabled":false}"#, #"{"isEnabled":false,"limit":null}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(BatteryCareSettings.self, from: Data(json.utf8)), json)
        }
    }

    func testSettingsRoundTripContainsOnlyRegularIntent() throws {
        let settings = try BatteryCareSettings(isEnabled: true, limit: 73)
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["isEnabled", "limit"])
        XCTAssertEqual(try JSONDecoder().decode(BatteryCareSettings.self, from: data), settings)
    }

    func testUnknownObservationsAndControlLayersRemainSeparate() throws {
        let sample = BatteryCareSample(
            identity: nil, presence: .unknown, sequence: 7, observedAtUptime: 123,
            systemPercentage: nil, externalPower: nil, isCharging: nil, lowBatteryProtection: nil
        )
        let settings = try BatteryCareSettings(isEnabled: true)
        let snapshot = BatteryCareSnapshot(settings: settings, sample: sample)
        XCTAssertNil(snapshot.sample?.identity)
        XCTAssertEqual(snapshot.sample?.presence, .unknown)
        XCTAssertNil(snapshot.sample?.systemPercentage)
        XCTAssertNil(snapshot.sample?.externalPower)
        XCTAssertNil(snapshot.sample?.isCharging)
        XCTAssertNil(snapshot.sample?.lowBatteryProtection)
        XCTAssertEqual(snapshot.sample?.sequence, 7)
        XCTAssertEqual(snapshot.sample?.observedAtUptime, 123)
        for operation in BatteryCareOperation.allCases {
            XCTAssertEqual(snapshot.capabilities[operation], .unverified)
        }
        XCTAssertEqual(snapshot.authorization, .notAuthorized)
        XCTAssertEqual(snapshot.requestStatus, .idle)
        XCTAssertEqual(snapshot.readback, .unknown)
        XCTAssertEqual(snapshot.physicalObservation, .unknown)
        XCTAssertEqual(snapshot.recoveryStatus, .unknown)
        XCTAssertNil(snapshot.safetyLimits)

        let requestID = UUID()
        let reply = BatteryCareReply(requestID: requestID, generation: 2, revision: 3, outcome: .accepted)
        XCTAssertEqual(reply.requestID, requestID)
        XCTAssertEqual(reply.generation, 2)
        XCTAssertEqual(reply.revision, 3)
        XCTAssertEqual(reply.outcome, .accepted)
        // Acceptance alone must not promote readback, physical observation or recovery.
        XCTAssertEqual(snapshot.readback, .unknown)
        XCTAssertEqual(snapshot.physicalObservation, .unknown)
        XCTAssertEqual(BatteryCareCompletion.unknown, .unknown)

        let transition = BatteryCareTransition(state: BatteryCareState(settings: settings), effects: [.endTemporaryMode, .releaseOwnedControls])
        XCTAssertEqual(transition.state.settings, settings)
        XCTAssertEqual(transition.state.confirmedPhase, .unknown)
        XCTAssertEqual(transition.state.temporaryMode, .none)
        XCTAssertNil(transition.state.pendingRequest)
        XCTAssertEqual(transition.state.recoveryStatus, .unknown)
        XCTAssertEqual(transition.effects, [.endTemporaryMode, .releaseOwnedControls])
    }

    func testSafetyLimitsRejectEveryZeroField() throws {
        // Synthetic nanoseconds, not production timing or a device validation record.
        for zeroIndex in 0..<8 {
            var values = Array(repeating: UInt64(1), count: 8)
            values[zeroIndex] = 0
            XCTAssertThrowsError(try makeLimits(values))
        }
        XCTAssertNoThrow(try makeLimits(Array(repeating: 1, count: 8)))
    }

    private func makeLimits(_ values: [UInt64]) throws -> BatteryCareSafetyLimits {
        try BatteryCareSafetyLimits(
            sampleIntervalNanoseconds: values[0], maxSampleAgeNanoseconds: values[1],
            maxCommandAgeNanoseconds: values[2], maxReadbackNanoseconds: values[3],
            maxStopNanoseconds: values[4], leaseNanoseconds: values[5],
            maxTemporaryModeNanoseconds: values[6], maxNoProgressNanoseconds: values[7]
        )
    }
}
