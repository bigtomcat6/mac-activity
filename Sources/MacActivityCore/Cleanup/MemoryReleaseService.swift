import Foundation

public protocol MemoryReadingProviding: Sendable {
    func memoryReading() async -> MemoryReading?
}

public struct LiveMemoryReadingProvider: MemoryReadingProviding {
    private let provider: MemoryProvider

    public init(provider: MemoryProvider = MemoryProvider()) {
        self.provider = provider
    }

    public func memoryReading() async -> MemoryReading? {
        guard case .memory(let reading) = await provider.sample() else {
            return nil
        }
        return reading
    }
}

public enum MemoryReleaseResult: Equatable, Sendable {
    case released(bytes: UInt64, percentOfTotal: Double)
    case unavailable
    case failed(exitCode: Int32)
    case failedToReadMemory
}

public struct MemoryReleaseService: Sendable {
    private let memoryReader: any MemoryReadingProviding
    private let cleaner: any MemoryCleaning

    public init(
        memoryReader: any MemoryReadingProviding = LiveMemoryReadingProvider(),
        cleaner: any MemoryCleaning = CleanMemoryService()
    ) {
        self.memoryReader = memoryReader
        self.cleaner = cleaner
    }

    public func currentReading() async -> MemoryReading? {
        await memoryReader.memoryReading()
    }

    public func release() async -> MemoryReleaseResult {
        guard let before = await memoryReader.memoryReading() else {
            return .failedToReadMemory
        }

        switch await cleaner.cleanMemory() {
        case .succeeded:
            guard let after = await memoryReader.memoryReading() else {
                return .failedToReadMemory
            }

            let reclaimedBytes = before.usedBytes > after.usedBytes
                ? before.usedBytes - after.usedBytes
                : 0
            let percentOfTotal = before.totalBytes > 0
                ? Double(reclaimedBytes) / Double(before.totalBytes) * 100
                : 0

            return .released(bytes: reclaimedBytes, percentOfTotal: percentOfTotal)
        case .unavailable:
            return .unavailable
        case .failed(let exitCode):
            return .failed(exitCode: exitCode)
        }
    }
}
