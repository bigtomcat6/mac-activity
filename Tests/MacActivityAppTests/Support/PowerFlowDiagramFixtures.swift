import Foundation
@testable import MacActivityCore
@testable import MacActivityApp

enum PowerFlowDiagramFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
    }

    static func endpoint(
        _ id: String,
        type: PowerFlowEndpointType,
        direction: PowerFlowDirection,
        measurement: PowerFlowMeasurement
    ) -> PowerFlowEndpoint {
        PowerFlowEndpoint(
            id: id,
            type: type,
            direction: direction,
            measurement: measurement
        )
    }

    static func snapshot(
        _ endpoints: [PowerFlowEndpoint],
        timestamp: Date = timestamp
    ) -> PowerFlowSnapshot {
        PowerFlowSnapshot(timestamp: timestamp, endpoints: endpoints)
    }

    static func snapshot(
        _ endpoints: PowerFlowEndpoint...,
        timestamp: Date = timestamp
    ) -> PowerFlowSnapshot {
        snapshot(endpoints, timestamp: timestamp)
    }
}
