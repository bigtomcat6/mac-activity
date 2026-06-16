import Foundation
import IOKit
import IOKit.ps

public struct BatteryProvider: MetricProvider {
    public let kind: MetricKind = .battery
    public let cadence: MetricCadenceLane = .slow
    private let readSystemBattery: @Sendable () -> BatteryReading?
    private let readHardwarePercentage: @Sendable () -> Double?

    public init() {
        self.init(
            readSystemBattery: Self.readSystemBattery,
            readHardwarePercentage: BatteryHardwareCapacityReader.readHardwarePercentage
        )
    }

    init(
        readSystemBattery: @escaping @Sendable () -> BatteryReading?,
        readHardwarePercentage: @escaping @Sendable () -> Double?
    ) {
        self.readSystemBattery = readSystemBattery
        self.readHardwarePercentage = readHardwarePercentage
    }

    public func sample() async -> MetricUpdate {
        guard var reading = readSystemBattery() else {
            return .unavailable(kind: .battery, reason: "Battery unavailable on this Mac")
        }

        reading.hardwarePercentage = readHardwarePercentage()
        return .battery(reading)
    }

    private static func readSystemBattery() -> BatteryReading? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let isPresent = description[kIOPSIsPresentKey as String] as? Bool ?? true
            guard isPresent else {
                continue
            }

            guard let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Double,
                  let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Double,
                  maxCapacity > 0 else {
                continue
            }

            let percentage = currentCapacity / maxCapacity * 100
            let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            return BatteryReading(percentage: percentage, isCharging: isCharging)
        }

        return nil
    }
}

enum BatteryHardwareCapacityReader {
    private static let serviceName = "AppleSmartBattery"
    private static let rawCurrentCapacityKey = "AppleRawCurrentCapacity"
    private static let rawMaxCapacityKey = "AppleRawMaxCapacity"

    static func readHardwarePercentage() -> Double? {
        guard let matching = IOServiceMatching(serviceName) else {
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return nil
        }
        defer {
            IOObjectRelease(service)
        }

        guard let currentCapacity = intProperty(rawCurrentCapacityKey, service: service),
              let maxCapacity = intProperty(rawMaxCapacityKey, service: service) else {
            return nil
        }

        return hardwarePercentage(currentCapacity: currentCapacity, maxCapacity: maxCapacity)
    }

    static func hardwarePercentage(currentCapacity: Int, maxCapacity: Int) -> Double? {
        guard maxCapacity > 0 else {
            return nil
        }

        let percentage = Double(currentCapacity) / Double(maxCapacity) * 100
        return min(100, max(0, percentage))
    }

    private static func intProperty(_ key: String, service: io_registry_entry_t) -> Int? {
        guard let number = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }

        return number.intValue
    }
}
