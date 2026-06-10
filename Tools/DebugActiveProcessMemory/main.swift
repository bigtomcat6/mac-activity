import AppKit
import Foundation
import MacActivityCore

private struct DebugActiveProcessOptions {
    var limit = 20
    var aggregateChildren = false
    var json = false
}

private struct DebugActiveProcessReport: Encodable {
    let schemaVersion: Int
    let aggregateChildren: Bool
    let limit: Int
    let rows: [DebugActiveProcessRow]
}

private struct DebugActiveProcessRow: Encodable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let mainResidentBytes: UInt64
    let childResidentBytes: UInt64
    let aggregateResidentBytes: UInt64
    let childCount: Int
}

@main
struct DebugActiveProcessMemory {
    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            let report = buildReport(options: options)
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

    private static func parseOptions(_ arguments: [String]) throws -> DebugActiveProcessOptions {
        var options = DebugActiveProcessOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                printUsage(to: stdout)
                exit(0)
            case "--limit":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let limit = Int(rawValue), limit > 0 else {
                    throw DebugActiveProcessError.invalidValue(argument: argument, value: rawValue)
                }
                options.limit = limit
            case "--aggregate-children":
                options.aggregateChildren = true
            case "--json":
                options.json = true
            default:
                throw DebugActiveProcessError.unknownArgument(argument)
            }

            index += 1
        }

        return options
    }

    private static func buildReport(options: DebugActiveProcessOptions) -> DebugActiveProcessReport {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        let rootPIDs = apps.map(\.processIdentifier)
        let snapshots = SystemProcessMemorySnapshotReader().snapshots()
        let aggregates = ProcessTreeResidentMemoryAggregator.aggregate(
            rootProcessIdentifiers: rootPIDs,
            snapshots: snapshots
        )
        let reader = MachProcessResidentMemoryReader()

        let rows = apps.compactMap { app -> DebugActiveProcessRow? in
            let pid = app.processIdentifier
            let aggregate = aggregates[pid]
            let mainResidentBytes = aggregate?.mainResidentBytes
                ?? reader.residentMemoryBytes(for: pid)
                ?? 0
            let childResidentBytes = options.aggregateChildren
                ? aggregate?.childResidentBytes ?? 0
                : 0
            let aggregateResidentBytes = options.aggregateChildren
                ? mainResidentBytes + childResidentBytes
                : mainResidentBytes

            guard aggregateResidentBytes > 0 else { return nil }

            return DebugActiveProcessRow(
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "Process \(pid)",
                bundleIdentifier: app.bundleIdentifier,
                mainResidentBytes: mainResidentBytes,
                childResidentBytes: childResidentBytes,
                aggregateResidentBytes: aggregateResidentBytes,
                childCount: options.aggregateChildren ? aggregate?.childCount ?? 0 : 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.aggregateResidentBytes == rhs.aggregateResidentBytes {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.aggregateResidentBytes > rhs.aggregateResidentBytes
        }
        .prefix(options.limit)
        .map { $0 }

        return DebugActiveProcessReport(
            schemaVersion: 1,
            aggregateChildren: options.aggregateChildren,
            limit: options.limit,
            rows: rows
        )
    }

    private static func printJSON(_ report: DebugActiveProcessReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fatalError("Unable to encode process memory report: \(error)")
        }
    }

    private static func printText(_ report: DebugActiveProcessReport) {
        print("MacActivity active process memory debug")
        print("aggregateChildren: \(report.aggregateChildren)")
        print("limit: \(report.limit)")
        print("")

        for row in report.rows {
            print("\(row.name) [pid \(row.pid)]")
            print("  main: \(format(row.mainResidentBytes)) (\(row.mainResidentBytes) bytes)")
            print("  child: \(format(row.childResidentBytes)) (\(row.childResidentBytes) bytes), count: \(row.childCount)")
            print("  aggregate: \(format(row.aggregateResidentBytes)) (\(row.aggregateResidentBytes) bytes)")
        }
    }

    private static func printUsage(to file: UnsafeMutablePointer<FILE>) {
        fputs("""
        Usage:
          scripts/debug-active-process-memory.command [--limit 20] [--aggregate-children] [--json]

        """, file)
    }

    private static func value(after argument: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw DebugActiveProcessError.missingValue(argument: argument)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

private enum DebugActiveProcessError: LocalizedError {
    case unknownArgument(String)
    case missingValue(argument: String)
    case invalidValue(argument: String, value: String)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .missingValue(let argument):
            return "Missing value after \(argument)"
        case .invalidValue(let argument, let value):
            return "Invalid value for \(argument): \(value)"
        }
    }
}

