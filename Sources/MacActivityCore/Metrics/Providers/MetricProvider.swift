import Foundation

public enum MetricCadenceLane: Int, CaseIterable, Sendable {
    case fast = 1
    case medium = 2
    case slow = 5

    public var seconds: Int {
        rawValue
    }
}

public protocol MetricProvider: Sendable {
    var kind: MetricKind { get }
    var cadence: MetricCadenceLane { get }
    func sample() async -> MetricUpdate
}
