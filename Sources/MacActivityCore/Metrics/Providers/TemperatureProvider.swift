import Foundation

public struct TemperatureProvider: MetricProvider {
    public let kind: MetricKind = .temperature
    public let cadence: MetricCadenceLane = .slow
    private let readTemperatureSource: @Sendable () async -> TemperatureSource
    private let readSMCTemperatureCelsius: @Sendable () -> Double?
    private let readBatteryTemperatureCelsius: @Sendable () -> Double?

    public init() {
        self.init(temperatureSourceStore: TemperatureSourceSelectionStore(initialSource: .smc))
    }

    public init(temperatureSourceStore: TemperatureSourceSelectionStore) {
        self.init(
            readTemperatureSource: {
                await temperatureSourceStore.read()
            },
            readSMCTemperatureCelsius: {
                SMCSensorReader.readTemperatureCelsius()
            },
            readBatteryTemperatureCelsius: {
                BatteryTemperatureReader.readTemperatureCelsius()
            }
        )
    }

    init(
        readTemperatureSource: @escaping @Sendable () async -> TemperatureSource,
        readSMCTemperatureCelsius: @escaping @Sendable () -> Double?,
        readBatteryTemperatureCelsius: @escaping @Sendable () -> Double?
    ) {
        self.readTemperatureSource = readTemperatureSource
        self.readSMCTemperatureCelsius = readSMCTemperatureCelsius
        self.readBatteryTemperatureCelsius = readBatteryTemperatureCelsius
    }

    public func sample() async -> MetricUpdate {
        let source = await readTemperatureSource()

        let reading: Double?
        let unavailableReason: String

        switch source {
        case .smc:
            reading = readSMCTemperatureCelsius()
            unavailableReason = "SMC temperature sensors are not available"
        case .battery:
            reading = readBatteryTemperatureCelsius()
            unavailableReason = "Battery temperature is not available"
        }

        guard let celsius = reading else {
            return .unavailable(kind: .temperature, reason: unavailableReason)
        }

        return .temperature(TemperatureReading(celsius: celsius, source: source))
    }
}
