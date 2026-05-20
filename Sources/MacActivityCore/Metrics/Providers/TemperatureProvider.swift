import Foundation

public struct TemperatureProvider: MetricProvider {
    public let kind: MetricKind = .temperature
    public let cadence: MetricCadenceLane = .slow

    public init() {}

    public func sample() async -> MetricUpdate {
        .unavailable(
            kind: .temperature,
            reason: "Temperature sensors are not available in the MVP build"
        )
    }
}
