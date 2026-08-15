import Foundation

public enum PowerFlowEndpointType: String, CaseIterable, Equatable, Sendable {
    case usbC
    case magSafe
    case battery
    case mac
    case unknownExternalInterface
}

public enum PowerFlowDirection: Equatable, Sendable {
    case input
    case output
    case idle
}

public enum PowerFlowMeasurement: Equatable, Sendable {
    case watts(Double)
    case unavailable

    public var watts: Double? {
        guard case .watts(let value) = self else { return nil }
        return value
    }
}

public struct PowerFlowEndpoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let type: PowerFlowEndpointType
    public let direction: PowerFlowDirection
    public let measurement: PowerFlowMeasurement

    public init(
        id: String,
        type: PowerFlowEndpointType,
        direction: PowerFlowDirection,
        measurement: PowerFlowMeasurement
    ) {
        self.id = id
        self.type = type
        self.direction = direction
        self.measurement = measurement
    }
}

public struct PowerFlowSnapshot: Equatable, Sendable {
    public let timestamp: Date
    public let endpoints: [PowerFlowEndpoint]

    public init(timestamp: Date = .now, endpoints: [PowerFlowEndpoint]) {
        self.timestamp = timestamp
        self.endpoints = endpoints
    }

    public static let empty = PowerFlowSnapshot(
        timestamp: .distantPast,
        endpoints: [
            PowerFlowEndpoint(
                id: "mac",
                type: .mac,
                direction: .output,
                measurement: .unavailable
            ),
        ]
    )

    public var inputEndpoints: [PowerFlowEndpoint] {
        endpoints.filter { $0.direction == .input }
    }

    public var outputEndpoints: [PowerFlowEndpoint] {
        endpoints.filter { $0.direction == .output }
    }
}

struct PowerFlowBatteryState: Equatable, Sendable {
    let direction: PowerFlowDirection
    let measurement: PowerFlowMeasurement
}

enum PowerFlowRules {
    static func batteryState(
        voltageMillivolts: Double?,
        amperageMilliamps: Double?,
        isCharging: Bool
    ) -> PowerFlowBatteryState {
        guard let voltageMillivolts,
              let amperageMilliamps,
              voltageMillivolts.isFinite,
              amperageMilliamps.isFinite,
              voltageMillivolts > 0,
              amperageMilliamps != 0 else {
            return PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        }

        let direction: PowerFlowDirection
        switch (amperageMilliamps.sign == .minus, isCharging) {
        case (true, false): direction = .input
        case (false, true): direction = .output
        default:
            return PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        }

        let watts = abs(voltageMillivolts * amperageMilliamps) / 1_000_000
        guard watts.isFinite, watts > 0 else {
            return PowerFlowBatteryState(direction: .idle, measurement: .unavailable)
        }
        return PowerFlowBatteryState(direction: direction, measurement: .watts(watts))
    }

    static func externalEndpointType(
        hasUSBPowerDeliveryMetadata: Bool,
        adapterDescription: String?
    ) -> PowerFlowEndpointType {
        if hasUSBPowerDeliveryMetadata { return .usbC }
        let description = adapterDescription?.lowercased() ?? ""
        if description.contains("magsafe") { return .magSafe }
        if description.contains("usb-c")
            || description.contains("usb c")
            || description.contains("usb pd")
            || description.contains("pd charger") {
            return .usbC
        }
        return .unknownExternalInterface
    }

    static func externalInputMeasurement(
        voltageMillivolts: Double?,
        currentMilliamps: Double?,
        reportedPowerMilliwatts: Double?
    ) -> PowerFlowMeasurement {
        guard let voltageMillivolts,
              let currentMilliamps,
              let reportedPowerMilliwatts,
              voltageMillivolts.isFinite,
              currentMilliamps.isFinite,
              reportedPowerMilliwatts.isFinite,
              voltageMillivolts > 0,
              currentMilliamps > 0,
              reportedPowerMilliwatts > 0 else {
            return .unavailable
        }

        let calculatedWatts = voltageMillivolts * currentMilliamps / 1_000_000
        let reportedWatts = reportedPowerMilliwatts / 1_000
        guard calculatedWatts.isFinite,
              reportedWatts.isFinite,
              calculatedWatts > 0,
              reportedWatts > 0 else {
            return .unavailable
        }

        let tolerance = max(0.5, max(calculatedWatts, reportedWatts) * 0.05)
        guard abs(calculatedWatts - reportedWatts) <= tolerance else {
            return .unavailable
        }
        return .watts(calculatedWatts)
    }

    static func macOutputMeasurement(
        systemLoadMilliwatts: Double?
    ) -> PowerFlowMeasurement {
        guard let systemLoadMilliwatts,
              systemLoadMilliwatts.isFinite,
              systemLoadMilliwatts > 0 else {
            return .unavailable
        }

        let watts = systemLoadMilliwatts / 1_000
        guard watts.isFinite, watts > 0 else {
            return .unavailable
        }
        return .watts(watts)
    }
}
