import Foundation

public struct TemperatureProvider: MetricProvider {
    public let kind: MetricKind = .temperature
    public let cadence: MetricCadenceLane = .medium
    private let readSMCTemperatureCelsius: @Sendable () async -> Double?
    private let readBatteryTemperatureCelsius: @Sendable () -> Double?

    public init() {
        self.init(smcSnapshotCache: .shared)
    }

    public init(temperatureSourceStore _: TemperatureSourceSelectionStore) {
        self.init()
    }

    init(
        temperatureSourceStore _: TemperatureSourceSelectionStore,
        smcSnapshotCache: SMCSensorSnapshotCache
    ) {
        self.init(
            smcSnapshotCache: smcSnapshotCache,
            readBatteryTemperatureCelsius: {
                BatteryTemperatureReader.readTemperatureCelsius()
            }
        )
    }

    init(
        smcSnapshotCache: SMCSensorSnapshotCache
    ) {
        self.init(
            smcSnapshotCache: smcSnapshotCache,
            readBatteryTemperatureCelsius: {
                BatteryTemperatureReader.readTemperatureCelsius()
            }
        )
    }

    init(
        readSMCTemperatureCelsius: @escaping @Sendable () -> Double?,
        readBatteryTemperatureCelsius: @escaping @Sendable () -> Double?
    ) {
        self.readSMCTemperatureCelsius = {
            readSMCTemperatureCelsius()
        }
        self.readBatteryTemperatureCelsius = readBatteryTemperatureCelsius
    }

    init(
        readTemperatureSource: @escaping @Sendable () async -> TemperatureSource,
        readSMCTemperatureCelsius: @escaping @Sendable () -> Double?,
        readBatteryTemperatureCelsius: @escaping @Sendable () -> Double?
    ) {
        self.init(
            readSMCTemperatureCelsius: readSMCTemperatureCelsius,
            readBatteryTemperatureCelsius: readBatteryTemperatureCelsius
        )
        _ = readTemperatureSource
    }

    init(
        smcSnapshotCache: SMCSensorSnapshotCache,
        readBatteryTemperatureCelsius: @escaping @Sendable () -> Double?
    ) {
        self.readSMCTemperatureCelsius = {
            await smcSnapshotCache.current().temperatureCelsius
        }
        self.readBatteryTemperatureCelsius = readBatteryTemperatureCelsius
    }

    public func sample() async -> MetricUpdate {
        let smcCelsius = await readSMCTemperatureCelsius()
        let batteryCelsius = readBatteryTemperatureCelsius()
        let readings = [
            smcCelsius.map { TemperatureReading(celsius: $0, source: .smc) },
            batteryCelsius.map { TemperatureReading(celsius: $0, source: .battery) }
        ].compactMap { $0 }

        switch readings.count {
        case 0:
            return .unavailable(kind: .temperature, reason: "Temperature sensors are not available")
        default:
            return .temperatures(readings)
        }
    }
}
