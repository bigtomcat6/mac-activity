import Foundation

public struct TemperatureProvider: MetricProvider {
    public let kind: MetricKind = .temperature
    public let cadence: MetricCadenceLane = .slow

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let celsius = SMCSensorReader.readTemperatureCelsius() else {
            return .unavailable(kind: .temperature, reason: "Temperature sensors are not exposed by AppleSMC")
        }

        return .temperature(TemperatureReading(celsius: celsius))
    }
}
