import Foundation
import IOKit
import IOKit.ps

enum SystemPowerFlowReader {
    static func read() -> PowerFlowRawReading {
        let timestamp = Date()
        let source = batteryPowerSourceDescription()
        let registry = batteryRegistryReading()
        let publicAdapter = externalAdapterDetails()
        let adapterDetails = registry.adapterDetails ?? publicAdapter
        let sourceState = source?[kIOPSPowerSourceStateKey as String] as? String
        let isBatteryPresent = (source?[kIOPSIsPresentKey as String] as? Bool) ?? registry.exists
        let isExternalPowerConnected = sourceState == kIOPSACPowerValue
            || registry.externalConnected
            || publicAdapter != nil

        let battery: PowerFlowRawBattery?
        if isBatteryPresent {
            battery = PowerFlowRawBattery(
                voltageMillivolts: registry.voltageMillivolts,
                amperageMilliamps: registry.instantAmperageMilliamps ?? registry.amperageMilliamps,
                isCharging: source?[kIOPSIsChargingKey as String] as? Bool ?? false
            )
        } else {
            battery = nil
        }

        let externalAdapter: PowerFlowRawExternalAdapter?
        if isExternalPowerConnected {
            externalAdapter = PowerFlowRawExternalAdapter(
                hasUSBPowerDeliveryMetadata: adapterDetails?["UsbHvcMenu"] != nil
                    || adapterDetails?["UsbHvcHvcIndex"] != nil,
                adapterDescription: adapterDetails?["Description"] as? String,
                reportedWatts: number(in: adapterDetails, key: "Watts"),
                reportedCurrentMilliamps: number(in: adapterDetails, key: "Current"),
                reportedVoltageMillivolts: number(in: adapterDetails, key: "AdapterVoltage")
            )
        } else {
            externalAdapter = nil
        }

        return PowerFlowRawReading(
            timestamp: timestamp,
            isExternalPowerConnected: isExternalPowerConnected,
            battery: battery,
            externalAdapter: externalAdapter,
            telemetry: registry.telemetry
        )
    }

    static func batteryPowerSourceDescription(
        snapshot: CFTypeRef?,
        sources: [CFTypeRef]?,
        descriptionForSource: (CFTypeRef, CFTypeRef) -> [String: Any]?
    ) -> [String: Any]? {
        guard let snapshot, let sources else { return nil }
        let descriptions = sources.compactMap { descriptionForSource(snapshot, $0) }
        return descriptions.first {
            ($0[kIOPSTypeKey as String] as? String) == kIOPSInternalBatteryType
        } ?? descriptions.first
    }

    static func powerTelemetryReading(_ details: [String: Any]?) -> PowerFlowRawTelemetry {
        PowerFlowRawTelemetry(
            inputVoltageMillivolts: number(in: details, key: "SystemVoltageIn"),
            inputCurrentMilliamps: number(in: details, key: "SystemCurrentIn"),
            inputPowerMilliwatts: number(in: details, key: "SystemPowerIn"),
            systemLoadMilliwatts: number(in: details, key: "SystemLoad")
        )
    }

    static func signedAmperage(from number: NSNumber) -> Double {
        Double(number.int32Value)
    }

    private struct BatteryRegistryReading {
        let exists: Bool
        let voltageMillivolts: Double?
        let instantAmperageMilliamps: Double?
        let amperageMilliamps: Double?
        let externalConnected: Bool
        let adapterDetails: [String: Any]?
        let telemetry: PowerFlowRawTelemetry
    }

    private static func batteryPowerSourceDescription() -> [String: Any]? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return nil
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?
            .takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        return batteryPowerSourceDescription(
            snapshot: snapshot,
            sources: sources,
            descriptionForSource: { snapshot, source in
                IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any]
            }
        )
    }

    private static func batteryRegistryReading() -> BatteryRegistryReading {
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return unavailableBatteryRegistryReading
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return unavailableBatteryRegistryReading
        }
        defer { IOObjectRelease(service) }

        return BatteryRegistryReading(
            exists: true,
            voltageMillivolts: doubleProperty("Voltage", service: service),
            instantAmperageMilliamps: signedAmperageProperty("InstantAmperage", service: service),
            amperageMilliamps: signedAmperageProperty("Amperage", service: service),
            externalConnected: boolProperty("ExternalConnected", service: service),
            adapterDetails: dictionaryProperty("AppleRawAdapterDetails", service: service)
                ?? dictionaryProperty("AdapterDetails", service: service),
            telemetry: powerTelemetryReading(
                dictionaryProperty("PowerTelemetryData", service: service)
            )
        )
    }

    private static var unavailableBatteryRegistryReading: BatteryRegistryReading {
        BatteryRegistryReading(
            exists: false,
            voltageMillivolts: nil,
            instantAmperageMilliamps: nil,
            amperageMilliamps: nil,
            externalConnected: false,
            adapterDetails: nil,
            telemetry: .unavailable
        )
    }

    private static func externalAdapterDetails() -> [String: Any]? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return details
    }

    private static func numberProperty(_ key: String, service: io_registry_entry_t) -> NSNumber? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber
    }

    private static func doubleProperty(_ key: String, service: io_registry_entry_t) -> Double? {
        numberProperty(key, service: service)?.doubleValue
    }

    private static func signedAmperageProperty(
        _ key: String,
        service: io_registry_entry_t
    ) -> Double? {
        numberProperty(key, service: service).map { signedAmperage(from: $0) }
    }

    private static func boolProperty(_ key: String, service: io_registry_entry_t) -> Bool {
        numberProperty(key, service: service)?.boolValue ?? false
    }

    private static func dictionaryProperty(
        _ key: String,
        service: io_registry_entry_t
    ) -> [String: Any]? {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        if let dictionary = value as? [String: Any] { return dictionary }
        return (value as? [Any])?.compactMap { $0 as? [String: Any] }.first
    }

    private static func number(in dictionary: [String: Any]?, key: String) -> Double? {
        (dictionary?[key] as? NSNumber)?.doubleValue
    }
}
