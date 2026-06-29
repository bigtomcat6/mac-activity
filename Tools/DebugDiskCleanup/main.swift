import Foundation
import MacActivityCore

private enum DebugDiskCleanupMode: String, Encodable {
    case scan
    case clean
}

private struct DebugDiskCleanupOptions {
    var mode: DebugDiskCleanupMode = .scan
    var categories = DiskCleanupCategoryKind.allCases
    var json = false
    var dryRun = false
    var confirm = false
    var showPaths = false
    var sampleLimit = 20
    var fixtureRoot: URL?
}

private struct DebugDiskCleanupReport: Encodable {
    let schemaVersion: Int
    let mode: DebugDiskCleanupMode
    let dryRun: Bool
    let categoriesRequested: [String]
    let fixtureRoot: String?
    let summary: DebugDiskCleanupSummaryReport
    let categories: [DebugDiskCleanupCategoryReport]
    let candidatesSample: [DebugDiskCleanupCandidateReport]
    let cleanResult: DebugDiskCleanupResultReport?
    let errors: [String]
}

private struct DebugDiskCleanupSummaryReport: Encodable {
    let totalBytes: UInt64
    let selectedBytes: UInt64
    let itemCount: Int
    let selectedItemCount: Int
    let accessIssueCount: Int

    static let zero = DebugDiskCleanupSummaryReport(
        totalBytes: 0,
        selectedBytes: 0,
        itemCount: 0,
        selectedItemCount: 0,
        accessIssueCount: 0
    )
}

private struct DebugDiskCleanupCategoryReport: Encodable {
    let kind: String
    let totalBytes: UInt64
    let selectedBytes: UInt64
    let itemCount: Int
    let selectedItemCount: Int
    let accessIssueCount: Int
}

private struct DebugDiskCleanupCandidateReport: Encodable {
    let kind: String
    let path: String
    let allocatedBytes: UInt64
    let deletionMode: String
    let reason: String
}

private struct DebugDiskCleanupResultReport: Encodable {
    let classification: String
    let cleanedBytes: UInt64
    let itemCount: Int
    let deletedCount: Int
    let failedCount: Int
    let remainingBytes: UInt64?
}

@main
struct DebugDiskCleanup {
    static func main() async {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            let report = await buildReport(options: options)
            if options.json {
                printJSON(report)
            } else {
                printText(report)
            }
        } catch {
            fputs("\(error.localizedDescription)\n\n", stderr)
            printUsage(to: stderr)
            exit(2)
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> DebugDiskCleanupOptions {
        var options = DebugDiskCleanupOptions()
        var cleanWasRequested = false
        var dryRunWasRequested = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                printUsage(to: stdout)
                exit(0)
            case "--scan":
                options.mode = .scan
            case "--clean":
                options.mode = .clean
                cleanWasRequested = true
            case "--dry-run":
                options.dryRun = true
                dryRunWasRequested = true
            case "--confirm":
                options.confirm = true
            case "--json":
                options.json = true
            case "--show-paths":
                options.showPaths = true
            case "--categories":
                let value = try value(after: argument, in: arguments, index: &index)
                options.categories = try parseCategories(value)
            case "--sample-limit":
                let value = try value(after: argument, in: arguments, index: &index)
                guard let sampleLimit = Int(value), sampleLimit >= 0 else {
                    throw DebugDiskCleanupError.invalidValue(argument: argument, value: value)
                }
                options.sampleLimit = sampleLimit
            case "--fixture-root":
                let value = try value(after: argument, in: arguments, index: &index)
                options.fixtureRoot = URL(fileURLWithPath: value, isDirectory: true)
            default:
                throw DebugDiskCleanupError.unknownArgument(argument)
            }

            index += 1
        }

        if options.mode == .clean, options.confirm == false, dryRunWasRequested == false {
            throw DebugDiskCleanupError.cleanRequiresConfirmationOrDryRun
        }

        if options.mode == .scan {
            options.dryRun = true
        } else if cleanWasRequested == false {
            options.mode = .scan
            options.dryRun = true
        }

        if options.mode == .clean,
           options.confirm,
           options.dryRun == false,
           let fixtureRoot = options.fixtureRoot,
           isSafeFixtureRootForConfirmedClean(fixtureRoot) == false {
            throw DebugDiskCleanupError.unsafeFixtureRoot(path: fixtureRoot.path)
        }

        return options
    }

    private static func buildReport(options: DebugDiskCleanupOptions) async -> DebugDiskCleanupReport {
        let roots = roots(for: options)
        let service = DiskCleanupService(roots: roots)

        if options.mode == .clean, options.confirm, options.dryRun == false {
            let result = await service.clean(categories: options.categories)
            let postScan = await service.scan(categories: options.categories)
            return report(
                options: options,
                roots: roots,
                scanResult: postScan,
                cleanResult: resultReport(for: result),
                errors: errors(from: postScan)
            )
        }

        let scanResult = await service.scan(categories: options.categories)
        return report(
            options: options,
            roots: roots,
            scanResult: scanResult,
            cleanResult: nil,
            errors: errors(from: scanResult)
        )
    }

    private static func report(
        options: DebugDiskCleanupOptions,
        roots: DiskCleanupRoots,
        scanResult: DiskCleanupScanResult,
        cleanResult: DebugDiskCleanupResultReport?,
        errors: [String]
    ) -> DebugDiskCleanupReport {
        let summary = summaryReport(from: scanResult)
        let categoryReports = categoryReports(from: scanResult)
        let candidateReports = candidateReports(
            from: scanResult,
            roots: roots,
            showPaths: options.showPaths,
            limit: options.sampleLimit
        )

        return DebugDiskCleanupReport(
            schemaVersion: 2,
            mode: options.mode,
            dryRun: options.mode == .scan || options.dryRun,
            categoriesRequested: options.categories.map(\.rawValue),
            fixtureRoot: fixtureRootReportPath(for: options),
            summary: summary,
            categories: categoryReports,
            candidatesSample: candidateReports,
            cleanResult: cleanResult,
            errors: errors
        )
    }

    private static func roots(for options: DebugDiskCleanupOptions) -> DiskCleanupRoots {
        guard let fixtureRoot = options.fixtureRoot else {
            return DiskCleanupRoots()
        }

        return DiskCleanupRoots(
            trashDirectory: fixtureRoot.appendingPathComponent(".Trash", isDirectory: true),
            userCachesDirectory: fixtureRoot
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true),
            userLogsDirectory: fixtureRoot
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
        )
    }

    private static func summaryReport(from result: DiskCleanupScanResult) -> DebugDiskCleanupSummaryReport {
        guard case .cleanable(let summary) = result else {
            return .zero
        }

        return DebugDiskCleanupSummaryReport(
            totalBytes: summary.totalBytes,
            selectedBytes: summary.selectedBytes,
            itemCount: summary.itemCount,
            selectedItemCount: summary.selectedItemCount,
            accessIssueCount: summary.accessIssueCount
        )
    }

    private static func categoryReports(from result: DiskCleanupScanResult) -> [DebugDiskCleanupCategoryReport] {
        guard case .cleanable(let summary) = result else {
            return []
        }

        return summary.categories.map { category in
            DebugDiskCleanupCategoryReport(
                kind: category.kind.rawValue,
                totalBytes: category.totalBytes,
                selectedBytes: category.selectedBytes,
                itemCount: category.itemCount,
                selectedItemCount: category.selectedItemCount,
                accessIssueCount: category.accessIssueCount
            )
        }
    }

    private static func candidateReports(
        from result: DiskCleanupScanResult,
        roots: DiskCleanupRoots,
        showPaths: Bool,
        limit: Int
    ) -> [DebugDiskCleanupCandidateReport] {
        guard case .cleanable(let summary) = result else {
            return []
        }

        return summary.candidates.prefix(limit).map { candidate in
            DebugDiskCleanupCandidateReport(
                kind: candidate.kind.rawValue,
                path: reportPath(for: candidate, roots: roots, showPaths: showPaths),
                allocatedBytes: candidate.allocatedBytes,
                deletionMode: candidate.deletionMode.rawValue,
                reason: candidate.reason
            )
        }
    }

    private static func resultReport(for result: DiskCleanupResult) -> DebugDiskCleanupResultReport {
        switch result {
        case .cleaned(let bytes, let itemCount):
            return DebugDiskCleanupResultReport(
                classification: "cleaned",
                cleanedBytes: bytes,
                itemCount: itemCount,
                deletedCount: itemCount,
                failedCount: 0,
                remainingBytes: 0
            )
        case .partial(let bytes, let deletedCount, let failedCount, let remainingBytes):
            return DebugDiskCleanupResultReport(
                classification: "partial",
                cleanedBytes: bytes,
                itemCount: deletedCount + failedCount,
                deletedCount: deletedCount,
                failedCount: failedCount,
                remainingBytes: remainingBytes
            )
        case .failed(let message):
            return DebugDiskCleanupResultReport(
                classification: "failed: \(message)",
                cleanedBytes: 0,
                itemCount: 0,
                deletedCount: 0,
                failedCount: 0,
                remainingBytes: nil
            )
        }
    }

    private static func errors(from result: DiskCleanupScanResult) -> [String] {
        switch result {
        case .clean, .cleanable:
            return []
        case .failed(let message):
            return [message]
        }
    }

    private static func reportPath(
        for candidate: DiskCleanupCandidate,
        roots: DiskCleanupRoots,
        showPaths: Bool
    ) -> String {
        guard showPaths == false else { return candidate.displayPath }

        let label = rootLabel(for: candidate.kind)
        let rootPath = roots.url(for: candidate.kind).standardizedFileURL.path
        let candidatePath = candidate.url.standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else {
            return "\(label)/<outside-root>"
        }

        let relativePath = String(candidatePath.dropFirst(rootPath.count + 1))
        return relativePath.isEmpty ? label : "\(label)/\(relativePath)"
    }

    private static func fixtureRootReportPath(for options: DebugDiskCleanupOptions) -> String? {
        guard let fixtureRoot = options.fixtureRoot else { return nil }
        return options.showPaths ? fixtureRoot.path : "<fixture>"
    }

    private static func rootLabel(for kind: DiskCleanupCategoryKind) -> String {
        switch kind {
        case .trash:
            return "<trash>"
        case .userCaches:
            return "<userCaches>"
        case .userLogs:
            return "<userLogs>"
        }
    }

    private static func isSafeFixtureRootForConfirmedClean(_ fixtureRoot: URL) -> Bool {
        let resolvedFixtureRoot = fixtureRoot.resolvingSymlinksInPath().standardizedFileURL
        let fixturePath = resolvedFixtureRoot.path
        guard resolvedFixtureRoot.lastPathComponent.hasPrefix("macactivity-") else {
            return false
        }

        return safeTemporaryRootPaths().contains { temporaryRootPath in
            fixturePath.hasPrefix(temporaryRootPath + "/")
        }
    }

    private static func safeTemporaryRootPaths() -> [String] {
        let roots = [
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            FileManager.default.temporaryDirectory
        ]

        return Array(Set(roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }))
    }

    private static func printJSON(_ report: DebugDiskCleanupReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            print(String(bytes: data, encoding: .utf8) ?? "")
        } catch {
            fatalError("Unable to encode disk cleanup report: \(error)")
        }
    }

    private static func printText(_ report: DebugDiskCleanupReport) {
        print("MacActivity disk cleanup debug")
        print("mode: \(report.mode.rawValue)")
        print("dryRun: \(report.dryRun)")
        if let fixtureRoot = report.fixtureRoot {
            print("fixtureRoot: \(fixtureRoot)")
        }
        print("categories: \(report.categoriesRequested.joined(separator: ","))")
        print("selected: \(format(report.summary.selectedBytes)) (\(report.summary.selectedBytes) bytes)")
        print("items: \(report.summary.selectedItemCount)")
        print("accessIssues: \(report.summary.accessIssueCount)")

        if let cleanResult = report.cleanResult {
            print("cleanResult: \(cleanResult.classification)")
            print("cleaned: \(format(cleanResult.cleanedBytes)) (\(cleanResult.cleanedBytes) bytes)")
            print("deleted: \(cleanResult.deletedCount), failed: \(cleanResult.failedCount)")
        }

        if report.categories.isEmpty == false {
            print("")
            for category in report.categories {
                print("\(category.kind): \(format(category.selectedBytes)) (\(category.selectedItemCount) items)")
            }
        }

        if report.errors.isEmpty == false {
            print("")
            print("errors:")
            for error in report.errors {
                print("  \(error)")
            }
        }
    }

    private static func printUsage(to file: UnsafeMutablePointer<FILE>) {
        fputs("""
        Usage:
          scripts/debug-disk-cleanup.command --scan [--categories trash,userCaches,userLogs] [--sample-limit 20] [--fixture-root PATH] [--show-paths] [--json]
          scripts/debug-disk-cleanup.command --clean --dry-run [--categories trash,userCaches,userLogs] [--fixture-root PATH] [--show-paths] [--json]
          scripts/debug-disk-cleanup.command --clean --confirm [--categories trash,userCaches,userLogs] [--fixture-root PATH] [--show-paths] [--json]

        Notes:
          --clean is non-destructive unless --confirm is present.
          --fixture-root remaps Trash/Caches/Logs under a test root.
          Confirmed fixture cleanup only allows macactivity-* directories under a system temporary root.
          Paths are redacted by default; pass --show-paths for full local paths.

        """, file)
    }

    private static func parseCategories(_ value: String) throws -> [DiskCleanupCategoryKind] {
        let categories = value.split(separator: ",").map(String.init).compactMap(DiskCleanupCategoryKind.init(rawValue:))
        if categories.isEmpty || categories.count != value.split(separator: ",").count {
            throw DebugDiskCleanupError.invalidValue(argument: "--categories", value: value)
        }
        return categories
    }

    private static func value(after argument: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw DebugDiskCleanupError.missingValue(argument: argument)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

private enum DebugDiskCleanupError: LocalizedError {
    case unknownArgument(String)
    case missingValue(argument: String)
    case invalidValue(argument: String, value: String)
    case cleanRequiresConfirmationOrDryRun
    case unsafeFixtureRoot(path: String)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .missingValue(let argument):
            return "Missing value after \(argument)"
        case .invalidValue(let argument, let value):
            return "Invalid value for \(argument): \(value)"
        case .cleanRequiresConfirmationOrDryRun:
            return "--clean requires --dry-run or --confirm"
        case .unsafeFixtureRoot(let path):
            return "--fixture-root \(path) is not allowed for --clean --confirm. Use a macactivity-* directory under /private/tmp or another system temporary root."
        }
    }
}
