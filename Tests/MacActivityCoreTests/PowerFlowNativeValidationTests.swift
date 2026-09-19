import Foundation
import XCTest
@testable import MacActivityCore

@MainActor
final class PowerFlowNativeValidationTests: XCTestCase {
    func testLiveSMCPowerFlowUsesCapturedReading() async throws {
        guard ProcessInfo.processInfo.environment["MACACTIVITY_POWER_FLOW_NATIVE_VALIDATION"] == "1" else {
            throw XCTSkip("Set MACACTIVITY_POWER_FLOW_NATIVE_VALIDATION=1 explicitly")
        }

        var previousTimestamp: Date?
        for index in 0..<3 {
            if index > 0 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }

            let raw = SystemPowerFlowReader.read()
            guard let battery = raw.battery else {
                if index == 0 {
                    throw XCTSkip("No internal battery is present on this Mac")
                }
                XCTFail("Internal battery was absent in sample \(index + 1)")
                return
            }
            guard raw.isExternalPowerConnected else {
                XCTFail("External power is required for native power-flow validation")
                return
            }

            let batteryVoltage = try XCTUnwrap(
                battery.voltageMillivolts,
                "Expected a decoded live battery voltage"
            )
            let batteryCurrent = try XCTUnwrap(
                battery.amperageMilliamps,
                "Expected a decoded live battery current"
            )
            let inputVoltage = try XCTUnwrap(
                raw.telemetry.inputVoltageMillivolts,
                "Expected a decoded live input voltage"
            )
            let inputCurrent = try XCTUnwrap(
                raw.telemetry.inputCurrentMilliamps,
                "Expected a decoded live input current"
            )
            XCTAssertTrue((5_000...20_000).contains(batteryVoltage))
            XCTAssertTrue(batteryCurrent.isFinite)
            XCTAssertTrue(inputVoltage.isFinite && inputVoltage > 0)
            XCTAssertTrue(inputCurrent.isFinite && inputCurrent >= 0)
            guard (5_000...20_000).contains(batteryVoltage),
                  batteryCurrent.isFinite,
                  inputVoltage.isFinite,
                  inputVoltage > 0,
                  inputCurrent.isFinite,
                  inputCurrent >= 0 else {
                return
            }

            let inputWatts = inputVoltage * inputCurrent / 1_000_000
            let batteryWatts = abs(batteryVoltage * batteryCurrent) / 1_000_000
            XCTAssertTrue(inputWatts.isFinite)
            XCTAssertTrue(batteryWatts.isFinite)
            guard inputWatts.isFinite, batteryWatts.isFinite else { return }

            let snapshot = await PowerFlowService(read: { raw }).snapshot()
            XCTAssertEqual(snapshot.timestamp, raw.timestamp)
            if let previousTimestamp {
                XCTAssertGreaterThan(raw.timestamp, previousTimestamp)
            }
            previousTimestamp = raw.timestamp

            let external = try XCTUnwrap(snapshot.endpoints.first { $0.id == "external-power" })
            let batteryEndpoint = try XCTUnwrap(snapshot.endpoints.first { $0.type == .battery })
            let mac = try XCTUnwrap(snapshot.endpoints.first { $0.type == .mac })
            let expectedBatteryDirection: PowerFlowDirection = batteryCurrent < 0
                ? .input
                : batteryCurrent > 0 ? .output : .idle
            XCTAssertEqual(external.direction, inputWatts == 0 ? .idle : .input)
            XCTAssertEqual(batteryEndpoint.direction, expectedBatteryDirection)
            XCTAssertEqual(
                try XCTUnwrap(external.measurement.watts),
                inputWatts,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                try XCTUnwrap(batteryEndpoint.measurement.watts),
                batteryWatts,
                accuracy: 0.000_001
            )

            let expectedMacWatts: Double
            switch expectedBatteryDirection {
            case .input:
                expectedMacWatts = inputWatts + batteryWatts
            case .output:
                expectedMacWatts = inputWatts - batteryWatts
            case .idle:
                expectedMacWatts = inputWatts
            }
            if expectedMacWatts > 0 {
                let macWatts = try XCTUnwrap(mac.measurement.watts)
                XCTAssertEqual(macWatts, expectedMacWatts, accuracy: 0.000_001)
                print("\(raw.timestamp.timeIntervalSince1970) \(inputWatts) \(batteryWatts) \(macWatts)")
            } else {
                XCTAssertEqual(mac.measurement, .unavailable)
                print("\(raw.timestamp.timeIntervalSince1970) \(inputWatts) \(batteryWatts) \(expectedMacWatts)")
            }
        }
    }
}
