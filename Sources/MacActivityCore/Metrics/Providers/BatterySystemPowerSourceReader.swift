import Foundation
import IOKit
import IOKit.ps

enum BatterySystemPowerSourceReader {
    static func readSystemBattery() -> BatteryReading? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }

            guard let reading = BatteryProvider.batteryReading(fromPowerSourceDescription: description) else {
                continue
            }

            return reading
        }

        return nil
    }
}
