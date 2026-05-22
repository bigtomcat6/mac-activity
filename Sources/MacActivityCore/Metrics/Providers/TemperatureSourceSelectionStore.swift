import Foundation

public actor TemperatureSourceSelectionStore {
    private var source: TemperatureSource

    public init(initialSource: TemperatureSource) {
        self.source = initialSource
    }

    public func read() -> TemperatureSource {
        source
    }

    public func set(_ source: TemperatureSource) {
        self.source = source
    }
}
