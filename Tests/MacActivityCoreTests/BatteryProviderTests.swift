import XCTest
import IOKit.ps
@testable import MacActivityCore

final class BatteryProviderTests: XCTestCase {
    func testDefaultProviderCanBeConstructed() {
        _ = BatteryProvider()
    }

    func testBatteryReadingUsesHardwarePercentageWhenRequestedAndAvailable() {
        let reading = BatteryReading(
            percentage: 79,
            isCharging: false,
            hardwarePercentage: 74.51
        )

        XCTAssertEqual(reading.displayPercentage(showsHardwarePercentage: true), 74.51, accuracy: 0.001)
        XCTAssertEqual(reading.displayPercentage(showsHardwarePercentage: false), 79, accuracy: 0.001)
    }

    func testBatteryReadingFallsBackToSystemPercentageWhenHardwarePercentageIsMissing() {
        let reading = BatteryReading(
            percentage: 79,
            isCharging: false,
            hardwarePercentage: nil
        )

        XCTAssertEqual(reading.displayPercentage(showsHardwarePercentage: true), 79, accuracy: 0.001)
    }

    func testBatteryReadingCanRepresentConnectedPowerWithoutCharging() {
        let reading = BatteryReading(
            percentage: 79,
            isCharging: false,
            isConnectedToPower: true
        )

        XCTAssertFalse(reading.isCharging)
        XCTAssertTrue(reading.isConnectedToPower)
    }

    func testPowerSourceDescriptionReadsConnectedPowerState() throws {
        let acPowerReading = try XCTUnwrap(
            BatteryProvider.batteryReading(
                fromPowerSourceDescription: [
                    kIOPSIsPresentKey as String: true,
                    kIOPSCurrentCapacityKey as String: 40.0,
                    kIOPSMaxCapacityKey as String: 80.0,
                    kIOPSIsChargingKey as String: false,
                    kIOPSPowerSourceStateKey as String: kIOPSACPowerValue
                ]
            )
        )
        let batteryPowerReading = try XCTUnwrap(
            BatteryProvider.batteryReading(
                fromPowerSourceDescription: [
                    kIOPSIsPresentKey as String: true,
                    kIOPSCurrentCapacityKey as String: 40.0,
                    kIOPSMaxCapacityKey as String: 80.0,
                    kIOPSIsChargingKey as String: false,
                    kIOPSPowerSourceStateKey as String: "Battery Power"
                ]
            )
        )

        XCTAssertEqual(
            acPowerReading,
            BatteryReading(percentage: 50, isCharging: false, isConnectedToPower: true)
        )
        XCTAssertEqual(
            batteryPowerReading,
            BatteryReading(percentage: 50, isCharging: false, isConnectedToPower: false)
        )
    }

    func testPowerSourceDescriptionRejectsUnavailableBatteryDescriptions() {
        XCTAssertNil(
            BatteryProvider.batteryReading(
                fromPowerSourceDescription: [
                    kIOPSIsPresentKey as String: false,
                    kIOPSCurrentCapacityKey as String: 40.0,
                    kIOPSMaxCapacityKey as String: 80.0
                ]
            )
        )
        XCTAssertNil(
            BatteryProvider.batteryReading(
                fromPowerSourceDescription: [
                    kIOPSIsPresentKey as String: true,
                    kIOPSCurrentCapacityKey as String: 40.0,
                    kIOPSMaxCapacityKey as String: 0.0
                ]
            )
        )
    }

    func testHardwareCapacityReaderComputesClampedPercentage() throws {
        XCTAssertEqual(
            try XCTUnwrap(BatteryHardwareCapacityReader.hardwarePercentage(currentCapacity: 4_680, maxCapacity: 6_281)),
            74.51,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(BatteryHardwareCapacityReader.hardwarePercentage(currentCapacity: 7_000, maxCapacity: 6_281)),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(BatteryHardwareCapacityReader.hardwarePercentage(currentCapacity: -1, maxCapacity: 6_281)),
            0,
            accuracy: 0.001
        )
        XCTAssertNil(BatteryHardwareCapacityReader.hardwarePercentage(currentCapacity: 4_680, maxCapacity: 0))
    }

    func testProviderAddsHardwarePercentageWhenAvailable() async {
        let provider = BatteryProvider(
            readSystemBattery: {
                BatteryReading(percentage: 79, isCharging: false)
            },
            readHardwarePercentage: {
                74.51
            }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            .battery(BatteryReading(percentage: 79, isCharging: false, hardwarePercentage: 74.51))
        )
    }

    func testProviderReportsUnavailableWhenSystemBatteryIsMissing() async {
        let provider = BatteryProvider(
            readSystemBattery: { nil },
            readHardwarePercentage: { 74.51 }
        )

        let update = await provider.sample()

        XCTAssertEqual(update, .unavailable(kind: .battery, reason: "Battery unavailable on this Mac"))
    }
}
