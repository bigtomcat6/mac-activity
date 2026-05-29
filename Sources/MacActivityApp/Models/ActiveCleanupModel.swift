import Combine
import Foundation
import MacActivityCore

@MainActor
protocol TrashCleanupServicing {
    func scan() async -> TrashScanResult
    func clean() async -> TrashCleanupResult
}

extension TrashCleanupService: TrashCleanupServicing {}

@MainActor
protocol MemoryReleaseServicing {
    func currentReading() async -> MemoryReading?
    func release() async -> MemoryReleaseResult
}

extension MemoryReleaseService: MemoryReleaseServicing {}

enum TrashState: Equatable {
    case idle
    case scanning
    case clean
    case cleanable(bytes: UInt64, itemCount: Int)
    case cleaning
    case cleaned(bytes: UInt64, itemCount: Int)
    case failed(String)
    case partial(bytes: UInt64, deletedCount: Int, failedCount: Int, remainingBytes: UInt64?)
}

enum MemoryState: Equatable {
    case idle
    case usage(percent: Double)
    case releasing(previousPercent: Double?)
    case released(bytes: UInt64, percentOfTotal: Double)
    case unavailable
    case failed(String)
    case failedToReadMemory
}

enum ProcessActionState: Equatable {
    case idle
    case requested(String)
    case notFound(String)
    case notTerminable(String)
}

@MainActor
final class ActiveCleanupModel: ObservableObject {
    @Published private(set) var trashState: TrashState = .idle
    @Published private(set) var memoryState: MemoryState = .idle
    @Published private(set) var processActionState: ProcessActionState = .idle
    @Published private(set) var apps: [ActiveAppMemoryEntry] = []
    @Published private(set) var isCleaningTrash = false
    @Published private(set) var isReleasingMemory = false
    @Published var isTrashConfirmationPresented = false

    private let trashService: any TrashCleanupServicing
    private let memoryService: any MemoryReleaseServicing
    private let appProvider: any ActiveAppMemoryProviding
    private let limit: Int

    init(
        trashService: any TrashCleanupServicing = TrashCleanupService(),
        memoryService: any MemoryReleaseServicing = MemoryReleaseService(),
        appProvider: any ActiveAppMemoryProviding = ActiveAppMemoryService(),
        limit: Int = 20
    ) {
        self.trashService = trashService
        self.memoryService = memoryService
        self.appProvider = appProvider
        self.limit = limit
    }

    func refresh() async {
        await refreshTrash()
        await refreshMemoryUsage()
        refreshApps()
    }

    func refreshTrash() async {
        trashState = .scanning
        trashState = mapScan(await trashService.scan())
    }

    func refreshMemoryUsage() async {
        guard let reading = await memoryService.currentReading() else {
            memoryState = .unavailable
            return
        }

        memoryState = .usage(percent: reading.pressurePercent)
    }

    func refreshApps() {
        apps = appProvider.topApps(limit: limit)
    }

    func requestTrashCleanupConfirmation() {
        isTrashConfirmationPresented = true
    }

    func confirmTrashCleanup() async {
        guard isCleaningTrash == false else { return }

        isTrashConfirmationPresented = false
        isCleaningTrash = true
        defer { isCleaningTrash = false }

        trashState = .cleaning

        switch await trashService.clean() {
        case .cleaned(let bytes, let itemCount):
            trashState = await stateAfterCleanedTrash(bytes: bytes, itemCount: itemCount)
        case .partial(let bytes, let deletedCount, let failedCount):
            let remainingBytes = await remainingBytesAfterPartialCleanup()
            trashState = .partial(
                bytes: bytes,
                deletedCount: deletedCount,
                failedCount: failedCount,
                remainingBytes: remainingBytes
            )
        case .failed(let message):
            trashState = .failed(message)
        }
    }

    func releaseMemory() async {
        guard isReleasingMemory == false else { return }

        let previousPercent = currentMemoryPercent
        isReleasingMemory = true
        memoryState = .releasing(previousPercent: previousPercent)

        switch await memoryService.release() {
        case .released(let bytes, let percentOfTotal):
            memoryState = .released(bytes: bytes, percentOfTotal: percentOfTotal)
        case .unavailable:
            memoryState = .unavailable
        case .failed(let exitCode):
            memoryState = .failed("Memory release failed with exit code \(exitCode).")
        case .failedToReadMemory:
            memoryState = .failedToReadMemory
        }

        isReleasingMemory = false
        refreshApps()
    }

    func quit(_ app: ActiveAppMemoryEntry) {
        switch appProvider.requestTermination(processIdentifier: app.processIdentifier) {
        case .requested:
            processActionState = .requested(app.name)
        case .notFound:
            processActionState = .notFound(app.name)
        case .notTerminable:
            processActionState = .notTerminable(app.name)
        }

        refreshApps()
    }

    private var currentMemoryPercent: Double? {
        switch memoryState {
        case .usage(let percent):
            return percent
        case .releasing(let previousPercent):
            return previousPercent
        case .idle, .released, .unavailable, .failed, .failedToReadMemory:
            return nil
        }
    }

    private func stateAfterCleanedTrash(bytes: UInt64, itemCount: Int) async -> TrashState {
        switch await trashService.scan() {
        case .clean:
            return .cleaned(bytes: bytes, itemCount: itemCount)
        case .cleanable(let remainingBytes, let remainingCount):
            return .cleanable(bytes: remainingBytes, itemCount: remainingCount)
        case .failed(let message):
            return .failed(message)
        }
    }

    private func remainingBytesAfterPartialCleanup() async -> UInt64? {
        switch await trashService.scan() {
        case .clean:
            return 0
        case .cleanable(let bytes, _):
            return bytes
        case .failed:
            return nil
        }
    }

    private func mapScan(_ result: TrashScanResult) -> TrashState {
        switch result {
        case .clean:
            return .clean
        case .cleanable(let bytes, let itemCount):
            return .cleanable(bytes: bytes, itemCount: itemCount)
        case .failed(let message):
            return .failed(message)
        }
    }
}
