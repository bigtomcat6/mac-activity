import Foundation

struct PowerFlowRawBattery: Equatable, Sendable {
    let voltageMillivolts: Double?
    let amperageMilliamps: Double?
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

    static let unavailable = PowerFlowRawTelemetry(
        inputVoltageMillivolts: nil,
        inputCurrentMilliamps: nil
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

        let batteryState = if let battery = raw.battery {
            PowerFlowRules.batteryState(
                voltageMillivolts: battery.voltageMillivolts,
                amperageMilliamps: battery.amperageMilliamps
            )
        } else {
            PowerFlowBatteryState(direction: .idle, measurement: .watts(0))
        }
        let externalMeasurement = raw.isExternalPowerConnected
            ? PowerFlowRules.externalInputMeasurement(
                voltageMillivolts: raw.telemetry.inputVoltageMillivolts,
                currentMilliamps: raw.telemetry.inputCurrentMilliamps
            )
            : .watts(0)
        let macMeasurement = PowerFlowRules.macOutputMeasurement(
            externalInput: externalMeasurement,
            batteryState: batteryState
        )

        if raw.isExternalPowerConnected {
            let adapter = raw.externalAdapter
            endpoints.append(PowerFlowEndpoint(
                id: "external-power",
                type: PowerFlowRules.externalEndpointType(
                    hasUSBPowerDeliveryMetadata: adapter?.hasUSBPowerDeliveryMetadata ?? false,
                    adapterDescription: adapter?.adapterDescription
                ),
                direction: externalMeasurement.watts == 0 ? .idle : .input,
                measurement: externalMeasurement
            ))
        }

        if raw.battery != nil {
            endpoints.append(PowerFlowEndpoint(
                id: "battery",
                type: .battery,
                direction: batteryState.direction,
                measurement: batteryState.measurement
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
