import AudioNativePreflightKit
import Darwin
import Foundation

@main
@MainActor
struct AudioNativePreflight {
    static func main() {
        do {
            let arguments = try AudioNativePreflightArguments.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            let report = try AudioNativePreflightCollector(
                includeDeviceControls: arguments.includeDeviceControls
            ).collect()
            FileHandle.standardOutput.write(try AudioNativePreflightJSON.encode(report))
        } catch {
            let message = "AudioNativePreflight: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
