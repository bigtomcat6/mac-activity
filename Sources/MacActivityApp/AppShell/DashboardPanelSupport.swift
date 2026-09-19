import AppKit

@MainActor
final class DashboardPresentationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum DashboardPanelFactory {
    static let identifier = "MacActivity.dashboardPanel"

    static func makePanel(contentRect: NSRect) -> DashboardPresentationPanel {
        let panel = DashboardPresentationPanel(
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

@MainActor
enum DashboardPanelAnchor {
    static func screenRect(for view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let rectInWindow = view.convert(view.bounds, to: nil)
        let rect = window.convertToScreen(rectInWindow)
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return nil
        }
        return rect
    }

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

enum DashboardPanelPlacement {
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
        gap: CGFloat = defaultGap,
        edgeMargin: CGFloat = defaultEdgeMargin
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

@MainActor
final class DashboardEventMonitorBag {
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

    static func live() -> DashboardEventMonitorBag {
        DashboardEventMonitorBag(
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
