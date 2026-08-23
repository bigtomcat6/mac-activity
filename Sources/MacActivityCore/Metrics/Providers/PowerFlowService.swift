import Foundation

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

struct PowerFlowRawTelemetry: Equatable, Sendable {
    let inputVoltageMillivolts: Double?
    let inputCurrentMilliamps: Double?
    let inputPowerMilliwatts: Double?
    let systemLoadMilliwatts: Double?

    static let unavailable = PowerFlowRawTelemetry(
        inputVoltageMillivolts: nil,
        inputCurrentMilliamps: nil,
        inputPowerMilliwatts: nil,
        systemLoadMilliwatts: nil
    )
}

struct PowerFlowRawReading: Equatable, Sendable {
    let timestamp: Date
    let isExternalPowerConnected: Bool
    let battery: PowerFlowRawBattery?
    let externalAdapter: PowerFlowRawExternalAdapter?
    var telemetry: PowerFlowRawTelemetry = .unavailable
}

@MainActor
public final class PowerFlowService {
    private let read: @Sendable () -> PowerFlowRawReading

    public init() {
        read = SystemPowerFlowReader.read
    }

    init(read: @escaping @Sendable () -> PowerFlowRawReading) {
        self.read = read
    }

    public func snapshot() async -> PowerFlowSnapshot {
        let read = self.read
        let raw = await Task.detached(priority: .utility) { read() }.value
        var endpoints = [PowerFlowEndpoint]()

        let externalMeasurement = PowerFlowRules.externalInputMeasurement(
            voltageMillivolts: raw.telemetry.inputVoltageMillivolts,
            currentMilliamps: raw.telemetry.inputCurrentMilliamps,
            reportedPowerMilliwatts: raw.telemetry.inputPowerMilliwatts
        )
        let macMeasurement = PowerFlowRules.macOutputMeasurement(
            systemLoadMilliwatts: raw.telemetry.systemLoadMilliwatts
        )

        if raw.isExternalPowerConnected {
            let adapter = raw.externalAdapter
            endpoints.append(PowerFlowEndpoint(
                id: "external-power",
                type: PowerFlowRules.externalEndpointType(
                    hasUSBPowerDeliveryMetadata: adapter?.hasUSBPowerDeliveryMetadata ?? false,
                    adapterDescription: adapter?.adapterDescription
                ),
                direction: .input,
                measurement: externalMeasurement
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
            measurement: macMeasurement
        ))
        return PowerFlowSnapshot(timestamp: raw.timestamp, endpoints: endpoints)
    }
}
