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

    func testBatteryDischargeProducesAnInputFromSignedLiveCurrent() {
        let state = PowerFlowRules.batteryState(
            voltageMillivolts: 12_000,
            amperageMilliamps: -2_000
        )

        XCTAssertEqual(state.direction, .input)
        XCTAssertEqual(state.measurement, .watts(24))
    }

    func testBatteryChargeProducesAnOutputFromSignedLiveCurrent() {
        let state = PowerFlowRules.batteryState(
            voltageMillivolts: 12_000,
            amperageMilliamps: 1_500
        )

        XCTAssertEqual(state.direction, .output)
        XCTAssertEqual(state.measurement, .watts(18))
    }

    func testKnownZeroBatteryCurrentProducesIdleZeroWatts() {
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: nil,
                amperageMilliamps: 0
            ),
            PowerFlowBatteryState(direction: .idle, measurement: .watts(0))
        )
    }

    func testMissingBatteryCurrentProducesIdleUnavailable() {
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: 12_000,
                amperageMilliamps: nil
            ),
            PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        )
    }

    func testKnownBatteryDirectionSurvivesUnavailableVoltage() {
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: nil,
                amperageMilliamps: -2_000
            ),
            PowerFlowBatteryState(direction: .input, measurement: .unavailable)
        )
        XCTAssertEqual(
            PowerFlowRules.batteryState(
                voltageMillivolts: 0,
                amperageMilliamps: 1_500
            ),
            PowerFlowBatteryState(direction: .output, measurement: .unavailable)
        )
    }

    func testNonfiniteBatteryCurrentProducesIdleUnavailable() {
        for current in [Double.nan, Double.infinity] {
            XCTAssertEqual(
                PowerFlowRules.batteryState(
                    voltageMillivolts: 12_000,
                    amperageMilliamps: current
                ),
                PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
            )
        }
    }

    func testExternalInputMeasurementUsesLiveVoltageAndCurrent() {
        let measurement = PowerFlowRules.externalInputMeasurement(
            voltageMillivolts: 19_654,
            currentMilliamps: 1_399
        )

        guard case .watts(let watts) = measurement else {
            return XCTFail("Expected a live input measurement")
        }
        XCTAssertEqual(watts, 27.496, accuracy: 0.001)
    }

    func testExternalInputMeasurementReturnsZeroForKnownZeroCurrent() {
        XCTAssertEqual(
            PowerFlowRules.externalInputMeasurement(
                voltageMillivolts: 20_000,
                currentMilliamps: 0
            ),
            .watts(0)
        )
        XCTAssertEqual(
            PowerFlowRules.externalInputMeasurement(
                voltageMillivolts: 0,
                currentMilliamps: 0
            ),
            .watts(0)
        )
    }

    func testExternalInputMeasurementRejectsMissingAndInvalidLiveValues() {
        let invalidInputs: [(Double?, Double?)] = [
            (nil, 1_399),
            (19_654, nil),
            (0, 1_399),
            (-19_654, 0),
            (19_654, -1_399),
            (Double.nan, 1_399),
            (19_654, Double.infinity),
            (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
            (Double.leastNonzeroMagnitude, Double.leastNonzeroMagnitude),
        ]

        for (voltage, current) in invalidInputs {
            XCTAssertEqual(
                PowerFlowRules.externalInputMeasurement(
                    voltageMillivolts: voltage,
                    currentMilliamps: current
                ),
                .unavailable
            )
        }
    }

    func testMacOutputMeasurementAllocatesExternalAndBatteryContributions() {
        XCTAssertEqual(
            PowerFlowRules.macOutputMeasurement(
                externalInput: .watts(40),
                batteryState: PowerFlowBatteryState(direction: .output, measurement: .watts(18))
            ),
            .watts(22)
        )
        XCTAssertEqual(
            PowerFlowRules.macOutputMeasurement(
                externalInput: .watts(20),
                batteryState: PowerFlowBatteryState(direction: .input, measurement: .watts(24))
            ),
            .watts(44)
        )
    }

    func testMacOutputMeasurementRejectsUnavailableInvalidAndNonpositiveAllocations() {
        let invalidAllocations: [(PowerFlowMeasurement, PowerFlowBatteryState)] = [
            (.unavailable, PowerFlowBatteryState(direction: .idle, measurement: .watts(0))),
            (.watts(-1), PowerFlowBatteryState(direction: .idle, measurement: .watts(0))),
            (.watts(10), PowerFlowBatteryState(direction: .output, measurement: .watts(18))),
            (.watts(18), PowerFlowBatteryState(direction: .output, measurement: .watts(18))),
            (
                .watts(Double.greatestFiniteMagnitude),
                PowerFlowBatteryState(
                    direction: .input,
                    measurement: .watts(Double.greatestFiniteMagnitude)
                )
            ),
        ]

        for (externalInput, batteryState) in invalidAllocations {
            XCTAssertEqual(
                PowerFlowRules.macOutputMeasurement(
                    externalInput: externalInput,
                    batteryState: batteryState
                ),
                .unavailable
            )
        }
    }

    func testSnapshotFiltersIdleEndpointsFromBothVisibleColumns() {
        let snapshot = PowerFlowSnapshot(endpoints: [
            PowerFlowEndpoint(id: "battery", type: .battery, direction: .idle, measurement: .watts(0)),
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

    func testMeasurementWattsReturnsOnlyMeasuredPower() {
        XCTAssertEqual(PowerFlowMeasurement.watts(1.5).watts, 1.5)
        XCTAssertNil(PowerFlowMeasurement.unavailable.watts)
    }
}
