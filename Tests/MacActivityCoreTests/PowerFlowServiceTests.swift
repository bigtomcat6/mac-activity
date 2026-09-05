import IOKit.ps
import XCTest
@testable import MacActivityCore

private final class ReadThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadExecutions = 0

    func record(_ onMainThread: Bool) {
        lock.lock()
        if onMainThread { mainThreadExecutions += 1 }
        lock.unlock()
    }

    func mainThreadExecutionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadExecutions
    }
}

@MainActor
final class PowerFlowServiceTests: XCTestCase {
    func testServiceAllocatesMacOutputFromLiveSMCInputWithIdleBattery() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 7),
            isExternalPowerConnected: true,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: 0
            ),
            externalAdapter: nil,
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 1_468
            )
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .watts(29.36))
        XCTAssertEqual(
            snapshot.endpoints.first(where: { $0.type == .mac })?.measurement,
            .watts(29.36)
        )
    }

    func testServiceAllocatesMacOutputAfterBatteryCharging() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 2),
            isExternalPowerConnected: true,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: 1_500
            ),
            externalAdapter: nil,
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 2_000
            )
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.map(\.type), [.unknownExternalInterface])
        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .watts(40))
        XCTAssertEqual(snapshot.outputEndpoints.map(\.type), [.battery, .mac])
        XCTAssertEqual(snapshot.outputEndpoints.map(\.measurement), [.watts(18), .watts(22)])
    }

    func testServiceAllocatesMacOutputWithExternalInputAndBatteryDischarge() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 3),
            isExternalPowerConnected: true,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: -2_000
            ),
            externalAdapter: nil,
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 1_000
            )
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.map(\.type), [.unknownExternalInterface, .battery])
        XCTAssertEqual(snapshot.inputEndpoints.map(\.measurement), [.watts(20), .watts(24)])
        XCTAssertEqual(snapshot.outputEndpoints, [
            PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .watts(44)),
        ])
    }

    func testServiceIgnoresRetainedExternalInputWhileDisconnectedForBatteryOnlyPower() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 4),
            isExternalPowerConnected: false,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: -2_000
            ),
            externalAdapter: PowerFlowRawExternalAdapter(
                hasUSBPowerDeliveryMetadata: true,
                adapterDescription: "pd charger",
                reportedWatts: 65,
                reportedCurrentMilliamps: 3_250,
                reportedVoltageMillivolts: 20_000
            ),
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 2_000
            )
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints, [
            PowerFlowEndpoint(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
        ])
        XCTAssertEqual(snapshot.outputEndpoints, [
            PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .watts(24)),
        ])
        XCTAssertNil(snapshot.endpoints.first(where: { $0.id == "external-power" }))
    }

    func testServiceTreatsAbsentBatteryAsZeroContribution() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 5),
            isExternalPowerConnected: true,
            battery: nil,
            externalAdapter: nil,
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 1_000
            )
        )).snapshot()

        XCTAssertEqual(
            snapshot.endpoints.first(where: { $0.type == .mac })?.measurement,
            .watts(20)
        )
    }

    func testServiceDoesNotTreatPresentBatteryWithMissingCurrentAsZeroContribution() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 6),
            isExternalPowerConnected: true,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: nil
            ),
            externalAdapter: nil,
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 1_000
            )
        )).snapshot()

        XCTAssertEqual(
            snapshot.endpoints.first(where: { $0.type == .battery })?.measurement,
            .unavailable
        )
        XCTAssertEqual(
            snapshot.endpoints.first(where: { $0.type == .mac })?.measurement,
            .unavailable
        )
    }

    func testServiceKeepsConnectedMissingExternalInputVisibleAndUnavailable() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 8),
            isExternalPowerConnected: true,
            battery: nil,
            externalAdapter: nil
        )).snapshot()

        XCTAssertEqual(snapshot.inputEndpoints.map(\.type), [.unknownExternalInterface])
        XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .unavailable)
        XCTAssertEqual(snapshot.outputEndpoints.first?.measurement, .unavailable)
    }

    func testServiceHidesConnectedZeroExternalInputFromActiveInput() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 9),
            isExternalPowerConnected: true,
            battery: nil,
            externalAdapter: nil,
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 0
            )
        )).snapshot()

        XCTAssertTrue(snapshot.inputEndpoints.isEmpty)
        XCTAssertEqual(
            snapshot.endpoints.first(where: { $0.id == "external-power" })?.direction,
            .idle
        )
        XCTAssertEqual(snapshot.outputEndpoints.first?.measurement, .unavailable)
    }

    func testServiceRejectsNegativeMacAllocation() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 10),
            isExternalPowerConnected: true,
            battery: PowerFlowRawBattery(
                voltageMillivolts: 12_000,
                amperageMilliamps: 1_500
            ),
            externalAdapter: nil,
            telemetry: PowerFlowRawTelemetry(
                inputVoltageMillivolts: 20_000,
                inputCurrentMilliamps: 500
            )
        )).snapshot()

        XCTAssertEqual(snapshot.outputEndpoints.map(\.measurement), [.watts(18), .unavailable])
    }

    func testAdapterCapabilitiesNeverBecomeLiveInputPower() async {
        let service = PowerFlowService(read: {
            PowerFlowRawReading(
                timestamp: Date(timeIntervalSince1970: 11),
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
        XCTAssertEqual(snapshot.outputEndpoints.first?.measurement, .unavailable)
    }

    func testDesktopReadingContainsOnlyUnavailableMacOutput() async {
        let snapshot = await service(reading: PowerFlowRawReading(
            timestamp: Date(timeIntervalSince1970: 12),
            isExternalPowerConnected: false,
            battery: nil,
            externalAdapter: nil
        )).snapshot()

        XCTAssertTrue(snapshot.inputEndpoints.isEmpty)
        XCTAssertEqual(snapshot.outputEndpoints, [
            PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .unavailable),
        ])
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

    func testPowerSourceDescriptionIgnoresUPSOnlyDescription() {
        let result = SystemPowerFlowReader.batteryPowerSourceDescription(
            snapshot: NSObject(),
            sources: [NSObject()],
            descriptionForSource: { _, _ in [
                kIOPSTypeKey as String: "UPS",
                kIOPSIsPresentKey as String: true,
            ] }
        )
        XCTAssertNil(result)
    }

    func testInjectedReadClosureDoesNotRunOnMainThread() async {
        let recorder = ReadThreadRecorder()
        let service = PowerFlowService(read: {
            recorder.record(Thread.isMainThread)
            return PowerFlowRawReading(
                timestamp: Date(timeIntervalSince1970: 13),
                isExternalPowerConnected: false,
                battery: nil,
                externalAdapter: nil
            )
        })

        _ = await service.snapshot()

        XCTAssertEqual(recorder.mainThreadExecutionCount(), 0)
    }
}

@MainActor
private func service(reading: PowerFlowRawReading) -> PowerFlowService {
    PowerFlowService(read: { reading })
}
