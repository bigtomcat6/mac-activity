import Foundation

public struct FanProvider: MetricProvider {
    public let kind: MetricKind = .fan
    public let cadence: MetricCadenceLane = .slow

    public init() {}

    public func sample() async -> MetricUpdate {
        .unavailable(
            kind: .fan,
            reason: "Fan sensors are not available in the MVP build"
        )
    }
}
