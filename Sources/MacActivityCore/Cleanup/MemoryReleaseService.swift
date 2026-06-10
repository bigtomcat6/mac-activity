import Foundation
import Dispatch

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
    case noSignificantRelease(observedBytes: UInt64)
    case skippedCooldown(remainingSeconds: TimeInterval)
    case unavailable
    case failed(exitCode: Int32)
    case failedToReadMemory
}

public enum MemoryReleaseStrategy: String, CaseIterable, Equatable, Sendable {
    case local
    case purge
    case full
}

public struct MemoryReleaseMeasurementPolicy: Equatable, Sendable {
    public static let `default` = MemoryReleaseMeasurementPolicy()

    public let settleDelayNanoseconds: UInt64
    public let significanceThresholdBytes: UInt64

    public init(
        settleDelayNanoseconds: UInt64 = 1_000_000_000,
        significanceThresholdBytes: UInt64 = 1_024 * 1_024
    ) {
        self.settleDelayNanoseconds = settleDelayNanoseconds
        self.significanceThresholdBytes = significanceThresholdBytes
    }

    public static func immediateForTesting(significanceThresholdBytes: UInt64 = 1_024 * 1_024) -> Self {
        Self(settleDelayNanoseconds: 0, significanceThresholdBytes: significanceThresholdBytes)
    }
}

public struct MemoryReleaseCooldownPolicy: Equatable, Sendable {
    public static let `default` = MemoryReleaseCooldownPolicy()
    public static let disabled = MemoryReleaseCooldownPolicy(durationNanoseconds: 0)

    public let durationNanoseconds: UInt64

    public init(durationNanoseconds: UInt64 = 10_000_000_000) {
        self.durationNanoseconds = durationNanoseconds
    }
}

public actor MemoryReleaseCooldownGate {
    private var lastAttemptNanoseconds: UInt64?

    public init() {}

    public func beginAttempt(nowNanoseconds: UInt64, policy: MemoryReleaseCooldownPolicy) -> TimeInterval? {
        guard policy.durationNanoseconds > 0 else { return nil }

        if let lastAttemptNanoseconds {
            let cooldownEnd = lastAttemptNanoseconds.addingReportingOverflow(policy.durationNanoseconds)
            let end = cooldownEnd.overflow ? UInt64.max : cooldownEnd.partialValue
            if nowNanoseconds < end {
                return Double(end - nowNanoseconds) / 1_000_000_000
            }
        }

        lastAttemptNanoseconds = nowNanoseconds
        return nil
    }
}

public struct MemoryReleaseService: Sendable {
    private let memoryReader: any MemoryReadingProviding
    private let cleaner: any MemoryCleaning
    private let measurementPolicy: MemoryReleaseMeasurementPolicy
    private let cooldownPolicy: MemoryReleaseCooldownPolicy
    private let cooldownGate: MemoryReleaseCooldownGate
    private let nowNanoseconds: @Sendable () async -> UInt64
    private let sleeper: @Sendable (UInt64) async -> Void

    public init(
        memoryReader: any MemoryReadingProviding = LiveMemoryReadingProvider(),
        cleaner: any MemoryCleaning = CleanMemoryService(),
        measurementPolicy: MemoryReleaseMeasurementPolicy = .default,
        cooldownPolicy: MemoryReleaseCooldownPolicy = .default,
        cooldownGate: MemoryReleaseCooldownGate = MemoryReleaseCooldownGate(),
        nowNanoseconds: @escaping @Sendable () async -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleeper: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            guard nanoseconds > 0 else { return }
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.memoryReader = memoryReader
        self.cleaner = cleaner
        self.measurementPolicy = measurementPolicy
        self.cooldownPolicy = cooldownPolicy
        self.cooldownGate = cooldownGate
        self.nowNanoseconds = nowNanoseconds
        self.sleeper = sleeper
    }

    public func currentReading() async -> MemoryReading? {
        await memoryReader.memoryReading()
    }

    public func currentReleasableBytes() async -> UInt64? {
        await cleaner.estimatedReleasableBytes()
    }

    public func release() async -> MemoryReleaseResult {
        await release(strategy: .full)
    }

    public func release(strategy: MemoryReleaseStrategy) async -> MemoryReleaseResult {
        let now = await nowNanoseconds()
        if let remainingSeconds = await cooldownGate.beginAttempt(nowNanoseconds: now, policy: cooldownPolicy) {
            return .skippedCooldown(remainingSeconds: remainingSeconds)
        }

        guard let before = await memoryReader.memoryReading() else {
            return .failedToReadMemory
        }

        switch strategy {
        case .local:
            return await measuredRelease(strategy: .local, baseline: before)
        case .purge:
            return await measuredRelease(strategy: .purge, baseline: before)
        case .full:
            return await fullRelease(baseline: before)
        }
    }

    private func fullRelease(baseline before: MemoryReading) async -> MemoryReleaseResult {
        let local = await measuredClean(strategy: .local, baseline: before)
        switch local {
        case .measured(let releasedBytes):
            if isSignificant(releasedBytes) {
                return releasedResult(bytes: releasedBytes, totalBytes: before.totalBytes)
            }
            return await purgeFallbackAfterInsignificantLocalRelease(baseline: before)
        case .failedToReadMemory:
            return .failedToReadMemory
        case .unavailable, .failed:
            return await purgeFallbackAfterInsignificantLocalRelease(baseline: before)
        }
    }

    private func purgeFallbackAfterInsignificantLocalRelease(baseline before: MemoryReading) async -> MemoryReleaseResult {
        let purge = await measuredClean(strategy: .purge, baseline: before)
        switch purge {
        case .measured(let releasedBytes):
            return classifyRelease(bytes: releasedBytes, totalBytes: before.totalBytes)
        case .unavailable:
            return .unavailable
        case .failed(let exitCode):
            return .failed(exitCode: exitCode)
        case .failedToReadMemory:
            return .failedToReadMemory
        }
    }

    private func measuredRelease(strategy: MemoryReleaseStrategy, baseline before: MemoryReading) async -> MemoryReleaseResult {
        let result = await measuredClean(strategy: strategy, baseline: before)
        switch result {
        case .measured(let releasedBytes):
            return classifyRelease(bytes: releasedBytes, totalBytes: before.totalBytes)
        case .unavailable:
            return .unavailable
        case .failed(let exitCode):
            return .failed(exitCode: exitCode)
        case .failedToReadMemory:
            return .failedToReadMemory
        }
    }

    private func measuredClean(strategy: MemoryReleaseStrategy, baseline before: MemoryReading) async -> MeasuredCleanResult {
        switch await cleaner.cleanMemory(strategy: strategy) {
        case .succeeded:
            await sleeper(measurementPolicy.settleDelayNanoseconds)
            guard let after = await memoryReader.memoryReading() else {
                return .failedToReadMemory
            }

            let reclaimedBytes = before.usedBytes > after.usedBytes
                ? before.usedBytes - after.usedBytes
                : 0
            return .measured(releasedBytes: reclaimedBytes)
        case .unavailable:
            return .unavailable
        case .failed(let exitCode):
            return .failed(exitCode: exitCode)
        }
    }

    private func classifyRelease(bytes: UInt64, totalBytes: UInt64) -> MemoryReleaseResult {
        guard isSignificant(bytes) else {
            return .noSignificantRelease(observedBytes: bytes)
        }
        return releasedResult(bytes: bytes, totalBytes: totalBytes)
    }

    private func releasedResult(bytes: UInt64, totalBytes: UInt64) -> MemoryReleaseResult {
        let percentOfTotal = totalBytes > 0
            ? Double(bytes) / Double(totalBytes) * 100
            : 0

        return .released(bytes: bytes, percentOfTotal: percentOfTotal)
    }

    private func isSignificant(_ bytes: UInt64) -> Bool {
        bytes >= measurementPolicy.significanceThresholdBytes
    }
}

private enum MeasuredCleanResult: Equatable {
    case measured(releasedBytes: UInt64)
    case unavailable
    case failed(exitCode: Int32)
    case failedToReadMemory
}
