import Foundation

private enum MemoryReleaseUIScenario: String {
    case released
    case zeroRelease = "zero-release"
    case cooldown
    case failed
}

private struct DebugMemoryReleaseUIOptions {
    var scenario: MemoryReleaseUIScenario = .zeroRelease
    var bytes: UInt64 = 0
    var percent: Double = 0
    var remainingSeconds: Double = 10
    var locale = "en"
    var json = false
}

private struct DebugMemoryReleaseUIReport: Encodable {
    let schemaVersion: Int
    let scenario: String
    let locale: String
    let title: String
    let subtitle: String
}

@main
struct DebugMemoryReleaseUI {
    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            let report = try buildReport(options: options)
            if options.json {
                printJSON(report)
            } else {
                print("scenario: \(report.scenario)")
                print("locale: \(report.locale)")
                print("title: \(report.title)")
                print("subtitle: \(report.subtitle)")
            }
        } catch {
            fputs("\(error.localizedDescription)\n\n", stderr)
            printUsage(to: stderr)
            exit(2)
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> DebugMemoryReleaseUIOptions {
        var options = DebugMemoryReleaseUIOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                printUsage(to: stdout)
                exit(0)
            case "--scenario":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let scenario = MemoryReleaseUIScenario(rawValue: rawValue) else {
                    throw DebugMemoryReleaseUIError.invalidValue(argument: argument, value: rawValue)
                }
                options.scenario = scenario
            case "--bytes":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let bytes = UInt64(rawValue) else {
                    throw DebugMemoryReleaseUIError.invalidValue(argument: argument, value: rawValue)
                }
                options.bytes = bytes
            case "--percent":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let percent = Double(rawValue) else {
                    throw DebugMemoryReleaseUIError.invalidValue(argument: argument, value: rawValue)
                }
                options.percent = percent
            case "--remaining-seconds":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let seconds = Double(rawValue) else {
                    throw DebugMemoryReleaseUIError.invalidValue(argument: argument, value: rawValue)
                }
                options.remainingSeconds = seconds
            case "--locale":
                options.locale = try value(after: argument, in: arguments, index: &index)
            case "--json":
                options.json = true
            default:
                throw DebugMemoryReleaseUIError.unknownArgument(argument)
            }

            index += 1
        }

        return options
    }

    private static func buildReport(options: DebugMemoryReleaseUIOptions) throws -> DebugMemoryReleaseUIReport {
        let strings = try localizedStrings(locale: options.locale)
        let locale = Locale(identifier: options.locale)

        let title: String
        let subtitle: String

        switch options.scenario {
        case .released:
            title = format(
                strings["memoryRelease.title.released"],
                arguments: [formattedBytes(options.bytes)],
                locale: locale
            )
            subtitle = format(
                strings["memoryRelease.subtitle.percentOfTotal"],
                arguments: [options.percent],
                locale: locale
            )
        case .zeroRelease:
            title = strings["memoryRelease.title.noSignificantRelease"]
                ?? "Memory Unchanged"
            subtitle = strings["memoryRelease.subtitle.noSignificantRelease"]
                ?? "No immediately releasable memory was found."
        case .cooldown:
            title = strings["memoryRelease.title.cooldown"]
                ?? "Release Cooling Down"
            subtitle = format(
                strings["memoryRelease.subtitle.cooldown"],
                arguments: [options.remainingSeconds],
                locale: locale
            )
        case .failed:
            title = strings["memoryRelease.title.failed"]
                ?? "Memory Release Failed"
            subtitle = "Memory release failed with exit code 1."
        }

        return DebugMemoryReleaseUIReport(
            schemaVersion: 1,
            scenario: options.scenario.rawValue,
            locale: options.locale,
            title: title,
            subtitle: subtitle
        )
    }

    private static func localizedStrings(locale: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MacActivityApp/Resources")
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")

        guard let dictionary = NSDictionary(contentsOf: url) as? [String: String] else {
            throw DebugMemoryReleaseUIError.missingStrings(locale: locale)
        }

        return dictionary
    }

    private static func format(_ format: String?, arguments: [CVarArg], locale: Locale) -> String {
        String(format: format ?? "", locale: locale, arguments: arguments)
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private static func printJSON(_ report: DebugMemoryReleaseUIReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fatalError("Unable to encode UI report: \(error)")
        }
    }

    private static func printUsage(to file: UnsafeMutablePointer<FILE>) {
        fputs("""
        Usage:
          scripts/debug-memory-release-ui.command --scenario released --bytes 65536 --percent 0.2 [--locale en|zh-Hans] [--json]
          scripts/debug-memory-release-ui.command --scenario zero-release [--locale en|zh-Hans] [--json]
          scripts/debug-memory-release-ui.command --scenario cooldown --remaining-seconds 7.5 [--locale en|zh-Hans] [--json]
          scripts/debug-memory-release-ui.command --scenario failed [--locale en|zh-Hans] [--json]

        """, file)
    }

    private static func value(after argument: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw DebugMemoryReleaseUIError.missingValue(argument: argument)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}
private enum DebugMemoryReleaseUIError: LocalizedError {
    case unknownArgument(String)
    case missingValue(argument: String)
    case invalidValue(argument: String, value: String)
    case missingStrings(locale: String)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .missingValue(let argument):
            return "Missing value after \(argument)"
        case .invalidValue(let argument, let value):
            return "Invalid value for \(argument): \(value)"
        case .missingStrings(let locale):
            return "Unable to load Localizable.strings for locale \(locale)"
        }
    }
}
