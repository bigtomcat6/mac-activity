import Foundation
import IOKit.ps

public struct BatteryProvider: MetricProvider {
    public let kind: MetricKind = .battery
    public let cadence: MetricCadenceLane = .slow

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let reading = readBattery() else {
            return .unavailable(kind: .battery, reason: "Battery unavailable on this Mac")
        }

        return .battery(reading)
    }

    private func readBattery() -> BatteryReading? {
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
