import IOKit.ps
import XCTest
@testable import MacActivityCore

@MainActor
final class PowerFlowServiceTests: XCTestCase {
    func testServicePlacesDischargingBatteryInInputAndMacInOutput() async {
        let service = PowerFlowService(read: {
            PowerFlowRawReading(
                timestamp: Date(timeIntervalSince1970: 1),
                isExternalPowerConnected: false,
                battery: PowerFlowRawBattery(
                    voltageMillivolts: 12_000,
                    amperageMilliamps: -2_000,
                    isCharging: false
                ),
                externalAdapter: nil
            )
        })

        let snapshot = await service.snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.map(\.type), [.battery])
        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .watts(24))
        XCTAssertEqual(snapshot.outputEndpoints.map(\.type), [.mac])
        XCTAssertEqual(snapshot.outputEndpoints.first?.measurement, .unavailable)
    }

    func testAdapterCapabilitiesNeverBecomeLiveInputPower() async {
        let service = PowerFlowService(read: {
            PowerFlowRawReading(
                timestamp: Date(timeIntervalSince1970: 1),
                isExternalPowerConnected: true,
                battery: nil,
                externalAdapter: PowerFlowRawExternalAdapter(
                    hasUSBPowerDeliveryMetadata: true,
                    adapterDescription: "pd charger",
                    reportedWatts: 65,
                    reportedCurrentMilliamps: 3_250,
                    reportedVoltageMillivolts: 20_000
                )
            )
        })

        let snapshot = await service.snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.first?.type, .usbC)
        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .unavailable)
    }

    func testServiceMovesChargingBatteryToOutput() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 2),
            isExternalPowerConnected: true,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: 1_500,
                isCharging: true
            ),
            externalAdapter: nil
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.first?.type, .unknownExternalInterface)
        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .unavailable)
        XCTAssertEqual(snapshot.outputEndpoints.map(\.type), [.battery, .mac])
        XCTAssertEqual(snapshot.outputEndpoints.first?.measurement, .watts(18))
    }

    func testServiceKeepsIdleBatteryOutOfVisibleColumns() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 3),
            isExternalPowerConnected: false,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: 0,
                isCharging: false
            ),
            externalAdapter: nil
        )).snapshot()

        XCTAssertTrue(snapshot.inputEndpoints.isEmpty)
        XCTAssertEqual(snapshot.outputEndpoints.map(\.type), [.mac])
        XCTAssertEqual(snapshot.endpoints.first(where: { $0.type == .battery })?.direction, .idle)
    }

    func testServiceUsesMagSafeDescriptionOnlyWhenItContainsApprovedToken() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 4),
            isExternalPowerConnected: true,
            battery: nil,
            externalAdapter: PowerFlowRawExternalAdapter(
                hasUSBPowerDeliveryMetadata: false,
                adapterDescription: "MagSafe charger",
                reportedWatts: 140,
                reportedCurrentMilliamps: 7_000,
                reportedVoltageMillivolts: 20_000
            )
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.first?.type, .magSafe)
        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .unavailable)
    }

    func testServiceUsesUnknownExternalInterfaceForUnrecognizedDescription() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 5),
            isExternalPowerConnected: true,
            battery: nil,
            externalAdapter: PowerFlowRawExternalAdapter(
                hasUSBPowerDeliveryMetadata: false,
                adapterDescription: "desk dock",
                reportedWatts: 100,
                reportedCurrentMilliamps: 5_000,
                reportedVoltageMillivolts: 20_000
            )
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.first?.type, .unknownExternalInterface)
        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .unavailable)
    }

    func testDesktopReadingContainsOnlyUnavailableMacOutput() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 6),
            isExternalPowerConnected: false,
            battery: nil,
            externalAdapter: nil
        )).snapshot()

        XCTAssertTrue(snapshot.inputEndpoints.isEmpty)
        XCTAssertEqual(snapshot.outputEndpoints, [
            PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .unavailable),
        ])
    }

    func testServiceUsesValidatedLiveTelemetryForExternalInputAndMacOutput() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 7),
            isExternalPowerConnected: true,
            battery: nil,
            externalAdapter: PowerFlowRawExternalAdapter(
                hasUSBPowerDeliveryMetadata: true,
                adapterDescription: "pd charger",
                reportedWatts: 100,
                reportedCurrentMilliamps: 5_000,
                reportedVoltageMillivolts: 20_000
            ),
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 19_654,
                inputCurrentMilliamps: 1_399,
                inputPowerMilliwatts: 27_471,
                systemLoadMilliwatts: 27_471
            )
        )).snapshot()

        guard case .watts(let inputWatts) = snapshot.inputEndpoints.first?.measurement else {
            return XCTFail("Expected live external input watts")
        }
        guard case .watts(let macWatts) = snapshot.outputEndpoints.last?.measurement else {
            return XCTFail("Expected live Mac output watts")
        }
        XCTAssertEqual(inputWatts, 27.496, accuracy: 0.001)
        XCTAssertEqual(macWatts, 27.471, accuracy: 0.001)
    }

    func testServiceDoesNotFallBackToAdapterCapabilityWhenLiveTelemetryIsInvalid() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 8),
            isExternalPowerConnected: true,
            battery: nil,
            externalAdapter: PowerFlowRawExternalAdapter(
                hasUSBPowerDeliveryMetadata: true,
                adapterDescription: "pd charger",
                reportedWatts: 100,
                reportedCurrentMilliamps: 5_000,
                reportedVoltageMillivolts: 20_000
            ),
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 19_654,
                inputCurrentMilliamps: 1_399,
                inputPowerMilliwatts: 65_000,
                systemLoadMilliwatts: .nan
            )
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .unavailable)
        XCTAssertEqual(snapshot.outputEndpoints.last?.measurement, .unavailable)
    }

    func testPowerTelemetryReadingKeepsOnlyExpectedNumericValues() {
        let telemetry = SystemPowerFlowReader.powerTelemetryReading([
            "SystemVoltageIn": NSNumber(value: 19_654),
            "SystemCurrentIn": NSNumber(value: 1_399),
            "SystemPowerIn": NSNumber(value: 27_471),
            "SystemLoad": NSNumber(value: 27_471),
            "Unrelated": "ignored",
        ])

        XCTAssertEqual(telemetry.inputVoltageMillivolts, 19_654)
        XCTAssertEqual(telemetry.inputCurrentMilliamps, 1_399)
        XCTAssertEqual(telemetry.inputPowerMilliwatts, 27_471)
        XCTAssertEqual(telemetry.systemLoadMilliwatts, 27_471)
    }

    func testNilPowerSourceSnapshotYieldsNilDescription() {
        let result = SystemPowerFlowReader.batteryPowerSourceDescription(
            snapshot: nil,
            sources: [NSObject()],
            descriptionForSource: { _, _ in [:] }
        )
        XCTAssertNil(result)
    }

    func testNilPowerSourceSourceListYieldsNilDescription() {
        let result = SystemPowerFlowReader.batteryPowerSourceDescription(
            snapshot: NSObject(),
            sources: nil,
            descriptionForSource: { _, _ in [:] }
        )
        XCTAssertNil(result)
    }

    func testPowerSourceDescriptionPrefersInternalBatteryDescription() {
        let first = NSObject()
        let second = NSObject()
        let result = SystemPowerFlowReader.batteryPowerSourceDescription(
            snapshot: NSObject(),
            sources: [first, second],
            descriptionForSource: { _, source in
                source === first
                    ? [kIOPSTypeKey as String: "UPS"]
                    : [kIOPSTypeKey as String: kIOPSInternalBatteryType]
            }
        )
        XCTAssertEqual(result?[kIOPSTypeKey as String] as? String, kIOPSInternalBatteryType)
    }

    func testPowerSourceDescriptionFallsBackToFirstDescription() {
        let result = SystemPowerFlowReader.batteryPowerSourceDescription(
            snapshot: NSObject(),
            sources: [NSObject()],
            descriptionForSource: { _, _ in [kIOPSTypeKey as String: "UPS"] }
        )
        XCTAssertEqual(result?[kIOPSTypeKey as String] as? String, "UPS")
    }
}

@MainActor
private func service(reading: PowerFlowRawReading) -> PowerFlowService {
    PowerFlowService(read: { reading })
}
