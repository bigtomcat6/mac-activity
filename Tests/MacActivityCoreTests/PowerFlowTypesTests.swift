import Foundation
import XCTest
@testable import MacActivityCore

final class PowerFlowTypesTests: XCTestCase {
    func testStructuredUSBPowerDeliveryMetadataWinsConnectorClassification() {
        XCTAssertEqual(
            PowerFlowRules.externalEndpointType(
                hasUSBPowerDeliveryMetadata: true,
                adapterDescription: "MagSafe charger"
            ),
            .usbC
        )
    }

    func testControlledConnectorDescriptionTokensClassifyOnlyKnownValues() {
        XCTAssertEqual(
            PowerFlowRules.externalEndpointType(
                hasUSBPowerDeliveryMetadata: false,
                adapterDescription: "MagSafe charger"
            ),
            .magSafe
        )
        XCTAssertEqual(
            PowerFlowRules.externalEndpointType(
                hasUSBPowerDeliveryMetadata: false,
                adapterDescription: "pd charger"
            ),
            .usbC
        )
        XCTAssertEqual(
            PowerFlowRules.externalEndpointType(
                hasUSBPowerDeliveryMetadata: false,
                adapterDescription: "65 W wall supply"
            ),
            .unknownExternalInterface
        )
    }

    func testBatteryDischargeProducesAnInputWithAbsoluteWatts() {
        let state = PowerFlowRules.batteryState(
            voltageMillivolts: 12_000,
            amperageMilliamps: -2_000,
            isCharging: false
        )

        XCTAssertEqual(state.direction, .input)
        XCTAssertEqual(state.measurement, .watts(24))
    }

    func testBatteryChargeProducesAnOutputWithAbsoluteWatts() {
        let state = PowerFlowRules.batteryState(
            voltageMillivolts: 12_000,
            amperageMilliamps: 1_500,
            isCharging: true
        )

        XCTAssertEqual(state.direction, .output)
        XCTAssertEqual(state.measurement, .watts(18))
    }

    func testZeroAndContradictoryBatteryReadingsBecomeIdleUnavailable() {
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: 12_000,
                amperageMilliamps: 0,
                isCharging: false
            ),
            PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        )
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: 12_000,
                amperageMilliamps: 1_500,
                isCharging: false
            ),
            PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        )
    }

    func testSnapshotFiltersIdleEndpointsFromBothVisibleColumns() {
        let snapshot = PowerFlowSnapshot(endpoints: [
            PowerFlowEndpoint(id: "battery", type: .battery, direction: .idle, measurement: .unavailable),
            PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .unavailable),
        ])

        XCTAssertTrue(snapshot.inputEndpoints.isEmpty)
        XCTAssertEqual(snapshot.outputEndpoints.map(\.id), ["mac"])
    }

    func testEmptySnapshotKeepsUnavailableMacOutputVisible() {
        XCTAssertEqual(PowerFlowSnapshot.empty.inputEndpoints, [])
        XCTAssertEqual(
            PowerFlowSnapshot.empty.outputEndpoints,
            [PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .unavailable)]
        )
    }

    func testInvalidBatteryReadingsBecomeIdleUnavailable() {
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: -12_000,
                amperageMilliamps: 2_000,
                isCharging: false
            ),
            PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        )
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: 12_000,
                amperageMilliamps: .infinity,
                isCharging: true
            ),
            PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        )
    }

    func testKnownBatteryDirectionRemainsVisibleWhenWattsAreUnavailable() {
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: nil,
                amperageMilliamps: -2_000,
                isCharging: false
            ),
            PowerFlowBatteryState(direction: .input, measurement: .unavailable)
        )
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: .nan,
                amperageMilliamps: 1_500,
                isCharging: true
            ),
            PowerFlowBatteryState(direction: .output, measurement: .unavailable)
        )
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: .greatestFiniteMagnitude,
                amperageMilliamps: .greatestFiniteMagnitude,
                isCharging: true
            ),
            PowerFlowBatteryState(direction: .output, measurement: .unavailable)
        )
    }

    func testExternalInputMeasurementUsesMatchingLiveVoltageCurrentAndPower() {
        let measurement = PowerFlowRules.externalInputMeasurement(
            voltageMillivolts: 19_654,
            currentMilliamps: 1_399,
            reportedPowerMilliwatts: 27_471
        )

        guard case .watts(let watts) = measurement else {
            return XCTFail("Expected a validated live input measurement")
        }
        XCTAssertEqual(watts, 27.496, accuracy: 0.001)
    }

    func testExternalInputMeasurementRejectsInvalidOrInconsistentTelemetry() {
        let invalidInputs: [(Double?, Double?, Double?)] = [
            (nil, 1_399, 27_471),
            (19_654, nil, 27_471),
            (19_654, 1_399, nil),
            (0, 1_399, 27_471),
            (19_654, 0, 27_471),
            (19_654, 1_399, 0),
            (.nan, 1_399, 27_471),
            (19_654, .infinity, 27_471),
            (-19_654, 1_399, 27_471),
            (19_654, -1_399, 27_471),
            (19_654, 1_399, -27_471),
            (19_654, 1_399, 65_000),
        ]

        for (voltage, current, reportedPower) in invalidInputs {
            XCTAssertEqual(
                PowerFlowRules.externalInputMeasurement(
                    voltageMillivolts: voltage,
                    currentMilliamps: current,
                    reportedPowerMilliwatts: reportedPower
                ),
                .unavailable
            )
        }
    }

    func testMacOutputMeasurementUsesOnlyPositiveFiniteSystemLoad() {
        XCTAssertEqual(
            PowerFlowRules.macOutputMeasurement(systemLoadMilliwatts: 27_471),
            .watts(27.471)
        )

        for invalidLoad: Double? in [nil, 0, -1, .nan, .infinity] {
            XCTAssertEqual(
                PowerFlowRules.macOutputMeasurement(systemLoadMilliwatts: invalidLoad),
                .unavailable
            )
        }
    }

    func testMeasurementWattsReturnsOnlyMeasuredPower() {
        XCTAssertEqual(PowerFlowMeasurement.watts(1.5).watts, 1.5)
        XCTAssertNil(PowerFlowMeasurement.unavailable.watts)
    }

    func testExternalInputMeasurementRejectsOverflowedCalculation() {
        XCTAssertEqual(
            PowerFlowRules.externalInputMeasurement(
                voltageMillivolts: .greatestFiniteMagnitude,
                currentMilliamps: .greatestFiniteMagnitude,
                reportedPowerMilliwatts: .greatestFiniteMagnitude
            ),
            .unavailable
        )
    }

    func testMacOutputMeasurementConvertsLargestFiniteLoad() {
        XCTAssertEqual(
            PowerFlowRules.macOutputMeasurement(
                systemLoadMilliwatts: .greatestFiniteMagnitude
            ),
            .watts(.greatestFiniteMagnitude / 1_000)
        )
    }

    func testMacOutputMeasurementRejectsUnderflowedConversion() {
        XCTAssertEqual(
            PowerFlowRules.macOutputMeasurement(
                systemLoadMilliwatts: .leastNonzeroMagnitude
            ),
            .unavailable
        )
    }
}
