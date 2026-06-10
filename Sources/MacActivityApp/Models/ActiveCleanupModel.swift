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
protocol DiskCleanupServicing {
    func scan(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupScanResult
    func clean(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupResult
}

extension DiskCleanupService: DiskCleanupServicing {}

@MainActor
protocol MemoryReleaseServicing {
    func currentReading() async -> MemoryReading?
    func currentReleasableBytes() async -> UInt64?
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
    case usage(percent: Double, releasableBytes: UInt64)
    case releasing(previousPercent: Double?)
    case released(bytes: UInt64, percentOfTotal: Double)
    case noSignificantRelease(observedBytes: UInt64)
    case cooldown(remainingSeconds: TimeInterval)
    case unavailable
    case failed(String)
    case failedToReadMemory
}

enum DiskCleanupState: Equatable {
    case idle
    case scanning
    case clean
    case cleanable(bytes: UInt64, itemCount: Int, categoryCount: Int)
    case cleaning
    case cleaned(bytes: UInt64, itemCount: Int)
    case failed(String)
    case partial(bytes: UInt64, deletedCount: Int, failedCount: Int, remainingBytes: UInt64?)
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
    @Published private(set) var diskCleanupState: DiskCleanupState = .idle
    @Published private(set) var processActionState: ProcessActionState = .idle
    @Published private(set) var apps: [ActiveAppMemoryEntry] = []
    @Published private(set) var quittingProcessIdentifiers: Set<pid_t> = []
    @Published private(set) var isCleaningTrash = false
    @Published private(set) var isCleaningDiskCleanup = false
    @Published private(set) var isReleasingMemory = false
    @Published var isTrashConfirmationPresented = false
    @Published var isDiskCleanupConfirmationPresented = false

    private let trashService: any TrashCleanupServicing
    private let memoryService: any MemoryReleaseServicing
    private let diskCleanupService: any DiskCleanupServicing
    private let appProvider: any ActiveAppMemoryProviding
    private let diskCleanupCategories: [DiskCleanupCategoryKind]
    private let limit: Int
    private let quitRefreshIntervalNanoseconds: UInt64
    private let quitRefreshAttemptLimit: Int

    init(
        trashService: any TrashCleanupServicing = TrashCleanupService(),
        memoryService: any MemoryReleaseServicing = MemoryReleaseService(),
        diskCleanupService: any DiskCleanupServicing = DiskCleanupService(),
        diskCleanupCategories: [DiskCleanupCategoryKind] = [.trash, .userCaches, .userLogs],
        appProvider: any ActiveAppMemoryProviding = ActiveAppMemoryService(),
        limit: Int = 20,
        quitRefreshIntervalNanoseconds: UInt64 = 500_000_000,
        quitRefreshAttemptLimit: Int = 20
    ) {
        self.trashService = trashService
        self.memoryService = memoryService
        self.diskCleanupService = diskCleanupService
        self.diskCleanupCategories = diskCleanupCategories
        self.appProvider = appProvider
        self.limit = limit
        self.quitRefreshIntervalNanoseconds = quitRefreshIntervalNanoseconds
        self.quitRefreshAttemptLimit = quitRefreshAttemptLimit
    }

    func refresh() async {
        await refreshTrash()
        await refreshMemoryUsage()
        refreshApps()
    }

    func refreshVisibleCleanReleaseSections() async {
        await refreshDiskCleanup()
        refreshApps()
    }

    func refreshTrash() async {
        trashState = .scanning
        trashState = mapScan(await trashService.scan())
    }

    func refreshDiskCleanup() async {
        diskCleanupState = .scanning
        diskCleanupState = mapDiskScan(
            await diskCleanupService.scan(categories: diskCleanupCategories, now: Date())
        )
    }

    func refreshMemoryUsage() async {
        guard let reading = await memoryService.currentReading() else {
            memoryState = .unavailable
            return
        }

        let releasableBytes = await memoryService.currentReleasableBytes() ?? 0
        memoryState = .usage(percent: reading.pressurePercent, releasableBytes: releasableBytes)
    }

    func refreshApps() {
        let refreshedApps = appProvider.topApps(limit: limit)
        apps = refreshedApps
        reconcileQuittingProcesses(with: refreshedApps)
    }

    func requestTrashCleanupConfirmation() {
        isTrashConfirmationPresented = true
    }

    func requestDiskCleanupConfirmation() {
        isDiskCleanupConfirmationPresented = true
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

    func confirmDiskCleanup() async {
        guard isCleaningDiskCleanup == false else { return }

        isDiskCleanupConfirmationPresented = false
        isCleaningDiskCleanup = true
        defer { isCleaningDiskCleanup = false }

        diskCleanupState = .cleaning

        switch await diskCleanupService.clean(categories: diskCleanupCategories, now: Date()) {
        case .cleaned(let bytes, let itemCount):
            diskCleanupState = await stateAfterCleanedDiskCleanup(bytes: bytes, itemCount: itemCount)
        case .partial(let bytes, let deletedCount, let failedCount, _):
            let remainingBytes = await remainingBytesAfterPartialDiskCleanup()
            diskCleanupState = .partial(
                bytes: bytes,
                deletedCount: deletedCount,
                failedCount: failedCount,
                remainingBytes: remainingBytes
            )
        case .failed(let message):
            diskCleanupState = .failed(message)
        }
    }

    func releaseMemory() async {
        guard isReleasingMemory == false else { return }

        let previousPercent = currentMemoryPercent
        isReleasingMemory = true
        memoryState = .releasing(previousPercent: previousPercent)

        switch await memoryService.release() {
        case .released(let bytes, let percentOfTotal):
            if bytes > 0 {
                memoryState = .released(bytes: bytes, percentOfTotal: percentOfTotal)
            } else {
                await refreshMemoryUsage()
            }
        case .noSignificantRelease(let observedBytes):
            memoryState = .noSignificantRelease(observedBytes: observedBytes)
        case .skippedCooldown(let remainingSeconds):
            memoryState = .cooldown(remainingSeconds: remainingSeconds)
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
            markQuitPending(for: app.processIdentifier)
        case .notFound:
            processActionState = .notFound(app.name)
            clearQuitPending(for: app.processIdentifier)
        case .notTerminable:
            processActionState = .notTerminable(app.name)
            clearQuitPending(for: app.processIdentifier)
        }

        refreshApps()
    }

    func refreshQuittingProcessesUntilResolved() async {
        guard quittingProcessIdentifiers.isEmpty == false else { return }

        var remainingAttempts = quitRefreshAttemptLimit
        while quittingProcessIdentifiers.isEmpty == false && remainingAttempts > 0 {
            if quitRefreshIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: quitRefreshIntervalNanoseconds)
            }
            guard Task.isCancelled == false else { return }

            refreshApps()
            remainingAttempts -= 1
        }

        if remainingAttempts == 0 && quittingProcessIdentifiers.isEmpty == false {
            quittingProcessIdentifiers = []
        }
    }

    func isQuitPending(for processIdentifier: pid_t) -> Bool {
        quittingProcessIdentifiers.contains(processIdentifier)
    }

    private var currentMemoryPercent: Double? {
        switch memoryState {
        case .usage(let percent, _):
            return percent
        case .releasing(let previousPercent):
            return previousPercent
        case .idle, .released, .noSignificantRelease, .cooldown, .unavailable, .failed, .failedToReadMemory:
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

    private func stateAfterCleanedDiskCleanup(bytes: UInt64, itemCount: Int) async -> DiskCleanupState {
        switch await diskCleanupService.scan(categories: diskCleanupCategories, now: Date()) {
        case .clean:
            return .cleaned(bytes: bytes, itemCount: itemCount)
        case .cleanable(let summary):
            return .cleanable(
                bytes: summary.selectedBytes,
                itemCount: summary.selectedItemCount,
                categoryCount: summary.categories.count
            )
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

    private func remainingBytesAfterPartialDiskCleanup() async -> UInt64? {
        switch await diskCleanupService.scan(categories: diskCleanupCategories, now: Date()) {
        case .clean:
            return 0
        case .cleanable(let summary):
            return summary.selectedBytes
        case .failed:
            return nil
        }
    }

    private func markQuitPending(for processIdentifier: pid_t) {
        var pending = quittingProcessIdentifiers
        pending.insert(processIdentifier)
        quittingProcessIdentifiers = pending
    }

    private func clearQuitPending(for processIdentifier: pid_t) {
        var pending = quittingProcessIdentifiers
        pending.remove(processIdentifier)
        quittingProcessIdentifiers = pending
    }

    private func reconcileQuittingProcesses(with refreshedApps: [ActiveAppMemoryEntry]) {
        let visibleProcessIdentifiers = Set(refreshedApps.map(\.processIdentifier))
        let stillVisibleQuittingProcesses = quittingProcessIdentifiers.intersection(visibleProcessIdentifiers)
        if stillVisibleQuittingProcesses != quittingProcessIdentifiers {
            quittingProcessIdentifiers = stillVisibleQuittingProcesses
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

    private func mapDiskScan(_ result: DiskCleanupScanResult) -> DiskCleanupState {
        switch result {
        case .clean:
            return .clean
        case .cleanable(let summary):
            return .cleanable(
                bytes: summary.selectedBytes,
                itemCount: summary.selectedItemCount,
                categoryCount: summary.categories.count
            )
        case .failed(let message):
            return .failed(message)
        }
    }
}
