import Foundation
import IOKit
import IOKit.ps

struct PowerFlowRawBattery: Equatable, Sendable {
    let voltageMillivolts: Double?
    let amperageMilliamps: Double?
    let isCharging: Bool
}

struct PowerFlowRawExternalAdapter: Equatable, Sendable {
    let hasUSBPowerDeliveryMetadata: Bool
    let adapterDescription: String?
    let reportedWatts: Double?
    let reportedCurrentMilliamps: Double?
    let reportedVoltageMillivolts: Double?
}

struct PowerFlowRawReading: Equatable, Sendable {
    let timestamp: Date
    let isExternalPowerConnected: Bool
    let battery: PowerFlowRawBattery?
    let externalAdapter: PowerFlowRawExternalAdapter?
}

@MainActor
public final class PowerFlowService {
    private let read: () -> PowerFlowRawReading

    public init() {
        read = SystemPowerFlowReader.read
    }

    init(read: @escaping () -> PowerFlowRawReading) {
        self.read = read
    }

    public func snapshot() async -> PowerFlowSnapshot {
        let raw = read()
        var endpoints = [PowerFlowEndpoint]()

        if raw.isExternalPowerConnected {
            let adapter = raw.externalAdapter
            endpoints.append(PowerFlowEndpoint(
                id: "external-power",
                type: PowerFlowRules.externalEndpointType(
                    hasUSBPowerDeliveryMetadata: adapter?.hasUSBPowerDeliveryMetadata ?? false,
                    adapterDescription: adapter?.adapterDescription
                ),
                direction: .input,
                measurement: .unavailable
            ))
        }

        if let battery = raw.battery {
            let state = PowerFlowRules.batteryState(
                voltageMillivolts: battery.voltageMillivolts,
                amperageMilliamps: battery.amperageMilliamps,
                isCharging: battery.isCharging
            )
            endpoints.append(PowerFlowEndpoint(
                id: "battery",
                type: .battery,
                direction: state.direction,
                measurement: state.measurement
            ))
        }

        endpoints.append(PowerFlowEndpoint(
            id: "mac",
            type: .mac,
            direction: .output,
            measurement: .unavailable
        ))
        return PowerFlowSnapshot(timestamp: raw.timestamp, endpoints: endpoints)
    }
}

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
            externalAdapter: externalAdapter
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

    private struct BatteryRegistryReading {
        let exists: Bool
        let voltageMillivolts: Double?
        let instantAmperageMilliamps: Double?
        let amperageMilliamps: Double?
        let externalConnected: Bool
        let adapterDetails: [String: Any]?
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
            return BatteryRegistryReading(
                exists: false,
                voltageMillivolts: nil,
                instantAmperageMilliamps: nil,
                amperageMilliamps: nil,
                externalConnected: false,
                adapterDetails: nil
            )
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return BatteryRegistryReading(
                exists: false,
                voltageMillivolts: nil,
                instantAmperageMilliamps: nil,
                amperageMilliamps: nil,
                externalConnected: false,
                adapterDetails: nil
            )
        }
        defer { IOObjectRelease(service) }

        return BatteryRegistryReading(
            exists: true,
            voltageMillivolts: numberProperty("Voltage", service: service),
            instantAmperageMilliamps: numberProperty("InstantAmperage", service: service),
            amperageMilliamps: numberProperty("Amperage", service: service),
            externalConnected: boolProperty("ExternalConnected", service: service),
            adapterDetails: dictionaryProperty("AppleRawAdapterDetails", service: service)
                ?? dictionaryProperty("AdapterDetails", service: service)
        )
    }

    private static func externalAdapterDetails() -> [String: Any]? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return details
    }

    private static func numberProperty(_ key: String, service: io_registry_entry_t) -> Double? {
        guard let number = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return number.doubleValue
    }

    private static func boolProperty(_ key: String, service: io_registry_entry_t) -> Bool {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return false
        }
        return value.boolValue
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
