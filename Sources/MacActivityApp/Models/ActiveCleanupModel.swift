import Combine
import Foundation
import MacActivityCore

@MainActor
protocol DiskCleanupServicing {
    func scan(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupScanResult
    func clean(categories: [DiskCleanupCategoryKind], now: Date) async -> DiskCleanupResult
}

extension DiskCleanupService: DiskCleanupServicing {}

enum DiskCleanupState: Equatable {
    case idle
    case scanning
    case clean
    case cleanable(bytes: UInt64, itemCount: Int, categories: [DiskCleanupCategoryKind])
    case cleaning
    case cleaned(bytes: UInt64, itemCount: Int)
    case failed(DiskCleanupFailureReason)
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
    @Published private(set) var diskCleanupState: DiskCleanupState = .idle
    @Published private(set) var processActionState: ProcessActionState = .idle
    @Published private(set) var apps: [ActiveAppMemoryEntry] = []
    @Published private(set) var quittingProcessIdentifiers: Set<pid_t> = []
    @Published private(set) var isCleaningDiskCleanup = false

    private let diskCleanupService: any DiskCleanupServicing
    private let appProvider: any ActiveAppMemoryProviding
    private var diskCleanupCategories: [DiskCleanupCategoryKind]
    private let limit: Int
    private let quitRefreshIntervalNanoseconds: UInt64
    private let quitRefreshAttemptLimit: Int

    init(
        diskCleanupService: any DiskCleanupServicing = DiskCleanupService(),
        diskCleanupCategories: [DiskCleanupCategoryKind] = AppPreferences.defaultDiskCleanupCategories,
        appProvider: any ActiveAppMemoryProviding = ActiveAppMemoryService(),
        limit: Int = 20,
        quitRefreshIntervalNanoseconds: UInt64 = 500_000_000,
        quitRefreshAttemptLimit: Int = 20
    ) {
        self.diskCleanupService = diskCleanupService
        self.diskCleanupCategories = diskCleanupCategories
        self.appProvider = appProvider
        self.limit = limit
        self.quitRefreshIntervalNanoseconds = quitRefreshIntervalNanoseconds
        self.quitRefreshAttemptLimit = quitRefreshAttemptLimit
    }

    func setDiskCleanupCategories(_ categories: [DiskCleanupCategoryKind]) {
        diskCleanupCategories = categories
    }

    func refreshVisibleCleanReleaseSections() async {
        await refreshDiskCleanup()
        refreshApps()
    }

    func refreshDiskCleanup() async {
        diskCleanupState = .scanning
        diskCleanupState = mapDiskScan(
            await diskCleanupService.scan(categories: diskCleanupCategories, now: Date())
        )
    }

    func refreshApps() {
        let refreshedApps = appProvider.topApps(limit: limit)
        apps = refreshedApps
        reconcileQuittingProcesses(with: refreshedApps)
    }

    func confirmDiskCleanup() async {
        guard isCleaningDiskCleanup == false else { return }

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

    func quit(_ app: ActiveAppMemoryEntry) {
        switch appProvider.requestTermination(app) {
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

    private func stateAfterCleanedDiskCleanup(bytes: UInt64, itemCount: Int) async -> DiskCleanupState {
        switch await diskCleanupService.scan(categories: diskCleanupCategories, now: Date()) {
        case .clean:
            return .cleaned(bytes: bytes, itemCount: itemCount)
        case .cleanable(let summary):
            return .cleanable(
                bytes: summary.selectedBytes,
                itemCount: summary.selectedItemCount,
                categories: diskCleanupCategories
            )
        case .failed(let message):
            return .failed(.message(message))
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

    private func mapDiskScan(_ result: DiskCleanupScanResult) -> DiskCleanupState {
        switch result {
        case .clean:
            return .clean
        case .cleanable(let summary):
            return .cleanable(
                bytes: summary.selectedBytes,
                itemCount: summary.selectedItemCount,
                categories: diskCleanupCategories
            )
        case .failed(let message):
            return .failed(.message(message))
        }
    }
}
