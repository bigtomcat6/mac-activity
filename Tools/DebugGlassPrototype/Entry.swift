import AppKit

@main
enum DebugGlassPrototypeMain {
    @MainActor
    static func main() {
        DebugGlassPrototypeCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
}
