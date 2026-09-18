import AppKit
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class PrototypeApplication: NSObject, NSApplicationDelegate {
    private let options: PrototypeOptions
    private var statusItem: NSStatusItem?
    private var backdropWindow: PrototypeBackdropWindow?
    private var monitors: PrototypeMonitorBag?
    private var coordinator: PrototypeHostCoordinator?
    private var didReportAnchorUnavailable = false

    init(options: PrototypeOptions) {
        self.options = options
        super.init()
    }

    static func run(options: PrototypeOptions) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PrototypeApplication(options: options)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = PrototypeHostCoordinator(
            contextProvider: { [weak self] in self?.makeContext() },
            quit: { NSApp.terminate(nil) }
        )
        createStatusItem()

        if options.backdrop, let screen = NSScreen.main {
            backdropWindow = PrototypeBackdropWindow(screen: screen)
        }

        let bag = PrototypeMonitorBag.live()
        bag.observe(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ) { [weak self] _ in
            self?.coordinator?.refresh()
        }
        monitors = bag
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitors?.removeAll()
        monitors = nil
        coordinator?.close()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Glass Proto"
        item.button?.target = self
        item.button?.action = #selector(handleStatusClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func makeContext() -> PrototypeHostCoordinator.Context? {
        guard let button = statusItem?.button else { return nil }
        let screens = NSScreen.screens
        guard let anchorRect = PrototypeAnchorResolver.screenRect(for: button),
              PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
                  anchorRect,
                  screenFrames: screens.map(\.frame)
              ) else {
            reportAnchorUnavailable()
            return nil
        }
        didReportAnchorUnavailable = false
        let visibleFrame = PrototypePlacement.visibleFrame(for: anchorRect, screens: screens)

        let workspace = NSWorkspace.shared
        let resolution = PrototypePolicy.resolve(
            mode: coordinator?.mode ?? .standardPopover,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        return PrototypeHostCoordinator.Context(
            anchorView: button,
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            resolution: resolution
        )
    }

    private func reportAnchorUnavailable() {
        guard didReportAnchorUnavailable == false else { return }
        didReportAnchorUnavailable = true
        fputs(
            "DebugGlassPrototype: status-item anchor is unavailable or implausible; refusing to show the prototype panel.\n",
            stderr
        )
        let alert = NSAlert()
        alert.messageText = "Status item anchor unavailable"
        alert.informativeText = "The prototype will not clamp its panel from an implausible status-item position. Move the prototype status item into the menu bar, or use the smoke test."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            presentMenu(from: sender)
        } else {
            coordinator?.toggle()
        }
    }

    private func presentMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        for mode in PrototypeMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == coordinator?.mode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let syntheticItem = NSMenuItem(title: "Synthetic data · prototype only", action: nil, keyEquivalent: "")
        syntheticItem.isEnabled = false
        menu.addItem(syntheticItem)

        let dimmingItem = NSMenuItem(
            title: "Module dimming: \(Int((PrototypePolicy.clearModuleBackingOpacity * 100).rounded()))% flat (clear modes)",
            action: nil,
            keyEquivalent: ""
        )
        dimmingItem.isEnabled = false
        menu.addItem(dimmingItem)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let reduceTransparencyItem = NSMenuItem(
                title: "Reduce Transparency: clear modes use the standard popover host",
                action: nil,
                keyEquivalent: ""
            )
            reduceTransparencyItem.isEnabled = false
            menu.addItem(reduceTransparencyItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Prototype", action: #selector(quitPrototype), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = PrototypeMode(rawValue: rawValue) else { return }
        coordinator?.setMode(mode)
    }

    @objc private func quitPrototype() {
        NSApp.terminate(nil)
    }
}

@MainActor
enum DebugGlassPrototypeCLI {
    static func run(arguments: [String]) -> Never {
        let options: PrototypeOptions
        do {
            options = try PrototypeOptions.parse(arguments)
        } catch {
            fputs("\(error.localizedDescription)\n\n", stderr)
            printUsage(to: stderr)
            exit(2)
        }

        if options.help {
            printUsage(to: stdout)
            exit(0)
        }

        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard PrototypePolicy.isSupported(majorVersion: majorVersion) else {
            fputs("DebugGlassPrototype requires macOS 26.0; this runtime is unsupported.\n", stderr)
            if options.smokeTest == false {
                presentUnsupportedAlert()
            }
            exit(3)
        }

        if options.smokeTest {
            guard #available(macOS 26.0, *) else { exit(3) }
            let report = PrototypeSmokeTest.run(options: options)
            printJSON(report)
            exit(report.failure == nil ? 0 : 1)
        }

        if #available(macOS 26.0, *) {
            PrototypeApplication.run(options: options)
        }
        exit(0)
    }

    private static func presentUnsupportedAlert() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "DebugGlassPrototype requires macOS 26"
        alert.informativeText = "This experiment uses Liquid Glass APIs from macOS 26. The current runtime is unsupported."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    @available(macOS 26.0, *)
    private static func printJSON(_ report: PrototypeSmokeReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            print(String(bytes: data, encoding: .utf8) ?? "")
        } catch {
            fputs("Unable to encode smoke report: \(error)\n", stderr)
        }
    }

    private static func printUsage(to file: UnsafeMutablePointer<FILE>) {
        fputs(
            """
            Usage:
              swift run DebugGlassPrototype [--backdrop]
              swift run DebugGlassPrototype --smoke-test [--cycles N] [--capture-dir PATH] [--json]
              swift run DebugGlassPrototype --help

            Notes:
              Requires macOS 26.0; older runtimes report as unsupported.
              Synthetic data only; no real sampling, audio, cleanup, or providers.

            """,
            file
        )
    }
}

@available(macOS 26.0, *)
struct PrototypeSmokeReport: Encodable {
    let schemaVersion: Int
    let prototype: String
    let synthetic: Bool
    let macOSVersion: String
    let supported: Bool
    let anchorSource: String
    let reduceTransparency: Bool
    let increaseContrast: Bool
    let cycles: Int
    let modes: [PrototypeSmokeModeReport]
    let monitorCleanupOK: Bool
    let allPrototypeWindowsClosed: Bool
    let bitmapCaptureSamplesBehindWindow: Bool
    let captures: [String]
    let limitations: [String]
    let failure: String?
}

@available(macOS 26.0, *)
struct PrototypeSmokeModeReport: Encodable {
    var requestedMode: String
    var effectiveHost: String
    var cycles: Int
    var anchorScreenRect: String
    var visibleFrame: String
    var windowFrame: String?
    var frameWithinVisibleFrame: Bool?
    var monitorCountWhileOpen: Int
    var monitorCountAfterClose: Int
    var popoverShownWhileOpen: Bool?
    var popoverShownAfterClose: Bool?
    var panelShownWhileOpen: Bool?
    var isOpaque: Bool?
    var backgroundColorClear: Bool?
    var alphaValue: Double?
    var styleMask: UInt?
    var level: Int?
    var canBecomeKey: Bool?
    var hasShadow: Bool?
}

@available(macOS 26.0, *)
@MainActor
enum PrototypeSmokeTest {
    private final class CompletionFlag: @unchecked Sendable {
        var finished = false
    }

    static func run(options: PrototypeOptions) -> PrototypeSmokeReport {
        let completion = CompletionFlag()
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            guard completion.finished == false else { return }
            fputs("DebugGlassPrototype smoke test timed out\n", stderr)
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "GP"
        pump(0.4)

        guard let anchor = resolveSmokeAnchor(statusButton: statusItem.button) else {
            NSStatusBar.system.removeStatusItem(statusItem)
            completion.finished = true
            return failureReport(options: options, failure: "anchor-unavailable")
        }
        let anchorView = anchor.view
        let anchorRect = anchor.rect
        let anchorSource = anchor.source

        let screens = NSScreen.screens
        guard screens.isEmpty == false else {
            anchor.window?.close()
            NSStatusBar.system.removeStatusItem(statusItem)
            completion.finished = true
            return failureReport(options: options, failure: "no-screens-available")
        }

        let visibleFrame = PrototypePlacement.visibleFrame(for: anchorRect, screens: screens)
        let workspace = NSWorkspace.shared
        let reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        var failure: String?
        var monitorCleanupOK = true
        var modeReports: [PrototypeSmokeModeReport] = []
        var captures: [String] = []

        for mode in PrototypeMode.allCases {
            let resolution = PrototypePolicy.resolve(
                mode: mode,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            let coordinator = PrototypeHostCoordinator(
                contextProvider: {
                    PrototypeHostCoordinator.Context(
                        anchorView: anchorView,
                        anchorRect: anchorRect,
                        visibleFrame: visibleFrame,
                        resolution: resolution
                    )
                },
                quit: {}
            )
            coordinator.setMode(mode)

            var latestReport: PrototypeSmokeModeReport?
            for cycle in 0..<options.cycles {
                coordinator.show()
                pump(0.5)

                var report = makeModeReport(
                    mode: mode,
                    resolution: resolution,
                    cycles: cycle + 1,
                    coordinator: coordinator,
                    anchorRect: anchorRect,
                    visibleFrame: visibleFrame
                )

                coordinator.close()
                pump(0.6)
                report.monitorCountAfterClose = coordinator.activeMonitorCount
                report.popoverShownAfterClose = coordinator.popoverIsShown

                if report.monitorCountAfterClose != 0 {
                    monitorCleanupOK = false
                    failure = failure ?? "monitor-leak:\(mode.rawValue)"
                }
                if coordinator.isVisible {
                    failure = failure ?? "host-still-visible-after-close:\(mode.rawValue)"
                }
                if let modeFailure = PrototypeSmokeValidation.modeFailure(mode: mode, report: report) {
                    failure = failure ?? modeFailure
                }
                latestReport = report
            }

            if let latestReport {
                modeReports.append(latestReport)
            }

            if let directory = options.captureDirectory {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let file = url.appendingPathComponent("\(mode.rawValue).png")
                if captureDashboard(resolution: resolution, to: file) {
                    captures.append(file.path)
                } else {
                    failure = failure ?? "capture-failed:\(mode.rawValue)"
                }
            }
        }

        anchor.window?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
        pump(0.2)

        let leakedWindows = PrototypeSmokeValidation.leakedPrototypeWindows(in: NSApp.windows)
        let allWindowsClosed = leakedWindows.isEmpty
        if allWindowsClosed == false {
            failure = failure ?? "prototype-windows-still-open"
        }

        completion.finished = true

        let version = ProcessInfo.processInfo.operatingSystemVersion
        return PrototypeSmokeReport(
            schemaVersion: 2,
            prototype: "DebugGlassPrototype",
            synthetic: true,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            supported: true,
            anchorSource: anchorSource,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast,
            cycles: options.cycles,
            modes: modeReports,
            monitorCleanupOK: monitorCleanupOK,
            allPrototypeWindowsClosed: allWindowsClosed,
            bitmapCaptureSamplesBehindWindow: false,
            captures: captures,
            limitations: [
                "NSHostingView bitmap capture cannot sample behind-window or desktop glass.",
                "The smoke test does not synthesize real external mouse or keyboard events; it verifies window properties and monitor lifecycle only.",
                "Multi-display, Spaces/fullscreen, VoiceOver, and profiling require manual or separate evidence.",
            ],
            failure: failure
        )
    }

    private static func resolveSmokeAnchor(
        statusButton: NSStatusBarButton?
    ) -> (view: NSView, rect: NSRect, source: String, window: NSWindow?)? {
        if let statusButton,
           let rect = PrototypeAnchorResolver.screenRect(for: statusButton),
           PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
               rect,
               screenFrames: NSScreen.screens.map(\.frame)
           ) {
            return (statusButton, rect, "status-item", nil)
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let rect = NSRect(x: screen.frame.maxX - 60, y: screen.frame.maxY - 28, width: 24, height: 24)
        let window = PrototypeAnchorWindow(frame: rect)
        return (window.anchorView, rect, "synthetic-menu-bar", window)
    }

    private static func makeModeReport(
        mode: PrototypeMode,
        resolution: PrototypeResolution,
        cycles: Int,
        coordinator: PrototypeHostCoordinator,
        anchorRect: NSRect,
        visibleFrame: NSRect
    ) -> PrototypeSmokeModeReport {
        let panel = coordinator.currentPanel
        let popover = coordinator.currentPopover
        let window: NSWindow? = resolution.effectiveHost == .panel
            ? panel
            : popover.contentViewController?.view.window
        let frame = window?.frame

        return PrototypeSmokeModeReport(
            requestedMode: mode.rawValue,
            effectiveHost: resolution.effectiveHost.rawValue,
            cycles: cycles,
            anchorScreenRect: NSStringFromRect(anchorRect),
            visibleFrame: NSStringFromRect(visibleFrame),
            windowFrame: frame.map(NSStringFromRect),
            frameWithinVisibleFrame: frame.map { visibleFrame.insetBy(dx: -1, dy: -1).contains($0) },
            monitorCountWhileOpen: coordinator.activeMonitorCount,
            monitorCountAfterClose: -1,
            popoverShownWhileOpen: coordinator.popoverIsShown,
            popoverShownAfterClose: nil,
            panelShownWhileOpen: panel?.isVisible,
            isOpaque: panel?.isOpaque,
            backgroundColorClear: panel.map { $0.backgroundColor == NSColor.clear },
            alphaValue: panel.map { Double($0.alphaValue) },
            styleMask: panel?.styleMask.rawValue,
            level: panel?.level.rawValue,
            canBecomeKey: panel?.canBecomeKey,
            hasShadow: panel?.hasShadow
        )
    }

    private static func captureDashboard(
        resolution: PrototypeResolution,
        to url: URL
    ) -> Bool {
        let view = PrototypeDashboardView(resolution: resolution, onQuit: {})
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: PrototypeLayout.contentWidth,
            height: PrototypeLayout.fallbackHeight
        )
        hosting.layoutSubtreeIfNeeded()
        let fittingSize = hosting.fittingSize
        let height = fittingSize.height > 40 ? fittingSize.height : PrototypeLayout.fallbackHeight
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: PrototypeLayout.contentWidth,
            height: height
        )
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func failureReport(options: PrototypeOptions, failure: String) -> PrototypeSmokeReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let workspace = NSWorkspace.shared
        return PrototypeSmokeReport(
            schemaVersion: 2,
            prototype: "DebugGlassPrototype",
            synthetic: true,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            supported: true,
            anchorSource: "unresolved",
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            cycles: options.cycles,
            modes: [],
            monitorCleanupOK: false,
            allPrototypeWindowsClosed: false,
            bitmapCaptureSamplesBehindWindow: false,
            captures: [],
            limitations: [
                "Smoke test did not complete; see failure field.",
            ],
            failure: failure
        )
    }
}
