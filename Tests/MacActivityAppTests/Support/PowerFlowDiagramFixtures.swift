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

    static func presentation(
        endpoints: [PowerFlowEndpoint],
        isRefreshing: Bool = false
    ) -> PowerFlowDiagramPresentation {
        PowerFlowDiagramPresentationBuilder.build(
            snapshot: snapshot(endpoints), isRefreshing: isRefreshing, bundle: englishBundle
        )
    }

    static var oneToOne: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(21.46)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(21.46)),
        ])
    }

    // Historical single-lane comparison fixture.
    static var reference: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(41.5)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(41.5)),
        ])
    }

    static var oneToMany: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(56.8)),
            endpoint("battery", type: .battery, direction: .output, measurement: .watts(30.7)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(26.1)),
        ])
    }

    static var manyToOne: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(20)),
            endpoint("battery", type: .battery, direction: .input, measurement: .watts(24)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(44)),
        ])
    }

    static var manyToMany: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(45)),
            endpoint("unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(12)),
            endpoint("battery", type: .battery, direction: .output, measurement: .watts(30)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(27)),
        ])
    }

    /// Balanced counts but a >5% known-total gap: exercises the In/Out footer.
    static var unbalanced: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(45)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(27)),
        ])
    }

    /// Expanded many-to-many with one unavailable input: partial + unbalanced.
    static var partialMixed: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(45)),
            endpoint("unknown", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
            endpoint("battery", type: .battery, direction: .output, measurement: .watts(30)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(27)),
        ])
    }

    static var grouped: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(45)),
            endpoint("battery-source", type: .battery, direction: .input, measurement: .watts(12)),
            endpoint("unknown-source", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
            endpoint("battery-sink", type: .battery, direction: .output, measurement: .watts(30)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(27)),
        ])
    }

    static var missingSource: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(24)),
        ])
    }

    static var missingSink: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(24)),
        ])
    }

    static var batteryOnly: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("battery", type: .battery, direction: .input, measurement: .watts(24.3)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(24.3)),
        ])
    }

    static var knownUnknownInput: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(28.5)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(28.5)),
        ])
    }

    static var knownUnknownOutput: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(28.5)),
            endpoint("unknown", type: .unknownExternalInterface, direction: .output, measurement: .watts(28.5)),
        ])
    }

    static var unavailableActive: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .unavailable),
            endpoint("mac", type: .mac, direction: .output, measurement: .unavailable),
        ])
    }

    // User-supplied AlDente screenshots: exact visible values for comparison.
    static var screenshotExternal: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(21.07)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(21.07)),
        ])
    }

    static var screenshotBattery: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("battery", type: .battery, direction: .input, measurement: .watts(18.63)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(18.63)),
        ])
    }

    static var screenshotCharging: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(35.62)),
            endpoint("battery", type: .battery, direction: .output, measurement: .watts(15.52)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(20.10)),
        ])
    }

    static var screenshotCombined: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("source", type: .usbC, direction: .input, measurement: .watts(28.39)),
            endpoint("battery", type: .battery, direction: .input, measurement: .watts(32.93)),
            endpoint("mac", type: .mac, direction: .output, measurement: .watts(61.32)),
        ])
    }

    static var waiting: PowerFlowDiagramPresentation {
        PowerFlowDiagramPresentationBuilder.build(
            snapshot: .empty, isRefreshing: true, bundle: englishBundle
        )
    }

    static var idle: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("battery", type: .battery, direction: .idle, measurement: .watts(0)),
        ])
    }

    static var unavailable: PowerFlowDiagramPresentation {
        presentation(endpoints: [
            endpoint("battery", type: .battery, direction: .idle, measurement: .unavailable),
        ])
    }
}
