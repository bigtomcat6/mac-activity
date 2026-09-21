import AppKit

// MARK: - Modes

enum PrototypeMode: String, CaseIterable, Sendable {
    case standardPopover = "standard-popover"
    case clearPopover = "clear-popover"
    case transparentPanel = "transparent-panel"

    var displayName: String {
        switch self {
        case .standardPopover:
            return "Standard popover (regular glass)"
        case .clearPopover:
            return "Clear popover (clear glass + readability tint)"
        case .transparentPanel:
            return "Transparent panel (clear glass, no shell)"
        }
    }
}

// MARK: - Layout

enum PrototypeLayout {
    static let contentWidth: CGFloat = 420
    static let fallbackHeight: CGFloat = 480
}

// MARK: - Options

struct PrototypeOptions: Equatable {
    var smokeTest = false
    var captureDirectory: String?
    var backdrop = false
    var cycles = 3
    var help = false

    static func parse(_ arguments: [String]) throws -> PrototypeOptions {
        var options = PrototypeOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.help = true
            case "--smoke-test":
                options.smokeTest = true
            case "--json":
                break
            case "--backdrop":
                options.backdrop = true
            case "--capture-dir":
                options.captureDirectory = try value(after: argument, in: arguments, index: &index)
            case "--cycles":
                let rawValue = try value(after: argument, in: arguments, index: &index)
                guard let cycles = Int(rawValue), cycles > 0 else {
                    throw PrototypeOptionError.invalidValue(argument: argument, value: rawValue)
                }
                options.cycles = cycles
            default:
                throw PrototypeOptionError.unknownArgument(argument)
            }

            index += 1
        }

        return options
    }

    private static func value(
        after argument: String,
        in arguments: [String],
        index: inout Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw PrototypeOptionError.missingValue(argument: argument)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

enum PrototypeOptionError: LocalizedError {
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

// MARK: - Panel

@MainActor
final class PrototypePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum PrototypePanelFactory {
    static let identifier = "DebugGlassPrototype.panel"

    static func makePanel(contentRect: NSRect) -> PrototypePanel {
        let panel = PrototypePanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.alphaValue = 1
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        return panel
    }
}

// MARK: - Anchors

@MainActor
enum PrototypeAnchorResolver {
    static func screenRect(for view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let rectInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }
}

// MARK: - Monitor bag

@MainActor
final class PrototypeMonitorBag {
    typealias GlobalInstaller = (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    typealias LocalInstaller = (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    typealias MonitorRemover = (Any) -> Void
    typealias ObserverInstaller = (
        NotificationCenter,
        Notification.Name,
        Any?,
        @escaping (Notification) -> Void
    ) -> any NSObjectProtocol

    private let installGlobal: GlobalInstaller
    private let installLocal: LocalInstaller
    private let removeMonitor: MonitorRemover
    private let installObserver: ObserverInstaller
    private var removers: [() -> Void] = []

    init(
        installGlobal: @escaping GlobalInstaller,
        installLocal: @escaping LocalInstaller,
        removeMonitor: @escaping MonitorRemover,
        installObserver: @escaping ObserverInstaller
    ) {
        self.installGlobal = installGlobal
        self.installLocal = installLocal
        self.removeMonitor = removeMonitor
        self.installObserver = installObserver
    }

    static func live() -> PrototypeMonitorBag {
        PrototypeMonitorBag(
            installGlobal: { mask, handler in
                NSEvent.addGlobalMonitorForEvents(matching: mask) { handler($0) }
            },
            installLocal: { mask, handler in
                NSEvent.addLocalMonitorForEvents(matching: mask) { handler($0) }
            },
            removeMonitor: { token in
                NSEvent.removeMonitor(token)
            },
            installObserver: { center, name, object, handler in
                center.addObserver(forName: name, object: object, queue: .main) { handler($0) }
            }
        )
    }

    var activeCount: Int { removers.count }

    func addGlobal(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        guard let token = installGlobal(mask, handler) else { return }
        let removeMonitor = self.removeMonitor
        removers.append { removeMonitor(token) }
    }

    func addLocal(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        guard let token = installLocal(mask, handler) else { return }
        let removeMonitor = self.removeMonitor
        removers.append { removeMonitor(token) }
    }

    func observe(
        center: NotificationCenter = .default,
        name: Notification.Name,
        object: Any? = nil,
        handler: @escaping (Notification) -> Void
    ) {
        let token = installObserver(center, name, object, handler)
        removers.append { center.removeObserver(token) }
    }

    func removeAll() {
        let pending = removers
        removers.removeAll()
        pending.forEach { $0() }
    }
}

// MARK: - Placement

enum PrototypePlacement {
    static let defaultGap: CGFloat = 6
    static let defaultEdgeMargin: CGFloat = 8

    static func screenIndex(containing anchorRect: NSRect, screenFrames: [NSRect]) -> Int? {
        guard screenFrames.isEmpty == false else { return nil }

        let center = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        if let index = screenFrames.firstIndex(where: { $0.contains(center) }) {
            return index
        }

        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, frame) in screenFrames.enumerated() {
            let intersection = frame.intersection(anchorRect)
            guard intersection.isNull == false else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    static func panelFrame(
        anchorRect: NSRect,
        visibleFrame: NSRect,
        contentSize: NSSize,
        gap: CGFloat = PrototypePlacement.defaultGap,
        edgeMargin: CGFloat = PrototypePlacement.defaultEdgeMargin
    ) -> NSRect {
        let maxWidth = max(0, visibleFrame.width - edgeMargin * 2)
        let maxHeight = max(0, visibleFrame.height - edgeMargin * 2)
        let width = min(contentSize.width, maxWidth)
        let height = min(contentSize.height, maxHeight)

        let minX = visibleFrame.minX + edgeMargin
        let maxX = visibleFrame.maxX - edgeMargin - width
        let minY = visibleFrame.minY + edgeMargin
        let maxY = visibleFrame.maxY - edgeMargin - height

        let proposedX = anchorRect.midX - width / 2
        let proposedY = anchorRect.minY - gap - height
        let x = min(max(proposedX, minX), max(maxX, minX))
        let y = min(max(proposedY, minY), max(maxY, minY))

        return NSRect(x: x, y: y, width: width, height: height)
    }

    @MainActor
    static func visibleFrame(for anchorRect: NSRect, screens: [NSScreen]) -> NSRect {
        let frames = screens.map(\.frame)
        if let index = screenIndex(containing: anchorRect, screenFrames: frames) {
            return screens[index].visibleFrame
        }
        return (NSScreen.main ?? screens.first)?.visibleFrame ?? .zero
    }
}

// MARK: - Anchor plausibility

enum PrototypeAnchorPlausibility {
    static let menuBarBandHeight: CGFloat = 80

    static func isPlausibleMenuBarRect(_ rect: NSRect, screenFrames: [NSRect]) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return screenFrames.contains { screenFrame in
            let menuBarBand = NSRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - menuBarBandHeight,
                width: screenFrame.width,
                height: menuBarBandHeight
            )
            return screenFrame.intersects(rect) && menuBarBand.intersects(rect)
        }
    }
}

// MARK: - Policy

enum PrototypeGlassKind: Equatable, Sendable {
    case regular
    case clear
}

enum PrototypeForegroundStyle: Equatable, Sendable {
    case system
    case clearLight
}

enum PrototypeHostKind: String, Equatable, Sendable {
    case popover
    case panel
}

struct PrototypeAppearanceConfig: Equatable, Sendable {
    var glassKind: PrototypeGlassKind
    var foreground: PrototypeForegroundStyle
    var moduleBackingOpacity: Double
    var strokeOpacity: Double

    var usesClearReadability: Bool { foreground == .clearLight }
}

struct PrototypeResolution: Equatable, Sendable {
    var requestedMode: PrototypeMode
    var effectiveMode: PrototypeMode
    var effectiveHost: PrototypeHostKind
    var appearance: PrototypeAppearanceConfig
}

enum PrototypePolicy {
    static let defaultStrokeOpacity: Double = 0.16
    static let increasedContrastStrokeOpacity: Double = 0.42
    static let clearModuleBackingOpacity: Double = 0.70
    static let clearModuleBackingOpacityIncreasedContrast: Double = 0.85

    static func isSupported(majorVersion: Int) -> Bool {
        majorVersion >= 26
    }

    static func resolve(
        mode: PrototypeMode,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> PrototypeResolution {
        let strokeOpacity = increaseContrast ? increasedContrastStrokeOpacity : defaultStrokeOpacity
        let standardAppearance = PrototypeAppearanceConfig(
            glassKind: .regular,
            foreground: .system,
            moduleBackingOpacity: 0,
            strokeOpacity: strokeOpacity
        )

        switch mode {
        case .standardPopover:
            return PrototypeResolution(
                requestedMode: .standardPopover,
                effectiveMode: .standardPopover,
                effectiveHost: .popover,
                appearance: standardAppearance
            )
        case .clearPopover, .transparentPanel:
            if reduceTransparency {
                return PrototypeResolution(
                    requestedMode: mode,
                    effectiveMode: .standardPopover,
                    effectiveHost: .popover,
                    appearance: standardAppearance
                )
            }
            return PrototypeResolution(
                requestedMode: mode,
                effectiveMode: mode,
                effectiveHost: mode == .clearPopover ? .popover : .panel,
                appearance: PrototypeAppearanceConfig(
                    glassKind: .clear,
                    foreground: .clearLight,
                    moduleBackingOpacity: increaseContrast
                        ? clearModuleBackingOpacityIncreasedContrast
                        : clearModuleBackingOpacity,
                    strokeOpacity: strokeOpacity
                )
            )
        }
    }
}
