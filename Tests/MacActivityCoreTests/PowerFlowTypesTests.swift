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
                voltageMillivolts: .nan,
                amperageMilliamps: 2_000,
                isCharging: true
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
}
