import AppKit
import SwiftUI
import Symbols

/// The system owns selection, focus, input and accessibility; only the glyphs animate separately.
struct DashboardTabPicker: NSViewRepresentable {
    @Binding var selection: DashboardTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> DashboardTabPickerView {
        let view = DashboardTabPickerView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DashboardTabPickerView, context: Context) {
        view.onSelection = { tab in
            guard selection != tab else { return }
            selection = tab
        }
        view.update(selection: selection, reduceMotion: reduceMotion)
    }
}

final class DashboardTabPickerView: NSView {
    let control = NSSegmentedControl()
    private let tabs = DashboardTab.allCases
    private let icons = DashboardTab.allCases.map { _ in DashboardTabForeground() }
    private var nativeImages: [NSImage] = []
    private var selection: DashboardTab = .overview
    private var reduceMotion = false
    private var overlayVisible = false
    var onSelection: (DashboardTab) -> Void = { _ in }

    override var intrinsicContentSize: NSSize { control.intrinsicContentSize }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        control.segmentCount = tabs.count
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.trackingMode = .selectOne
        control.target = self
        control.action = #selector(selectSegment)
        addSubview(control)
        for icon in icons {
            icon.imageScaling = .scaleNone
            icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            icon.contentTintColor = .labelColor
            icon.setAccessibilityElement(false)
            icon.setAccessibilityHidden(true)
            icon.isHidden = true
            addSubview(icon)
        }
        update(selection: .overview, reduceMotion: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(selection: DashboardTab, reduceMotion: Bool) {
        let previous = self.selection
        self.selection = selection
        self.reduceMotion = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        control.selectedSegment = tabs.firstIndex(of: selection) ?? 0
        control.setAccessibilityLabel(AppLocalization.string(.dashboardSection))
        let images = tabs.map { NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: $0.title) ?? NSImage() }
        if nativeImages.map(\.accessibilityDescription) != images.map(\.accessibilityDescription) {
            nativeImages = images
            overlayVisible = false
            for i in tabs.indices {
                control.setImage(images[i], forSegment: i)
                control.setToolTip(tabs[i].title, forSegment: i)
            }
            invalidateIntrinsicContentSize()
        }
        refreshGeometry()
        for i in tabs.indices {
            let image = symbol(for: tabs[i])
            if #available(macOS 26.0, *) {
                if self.reduceMotion || !overlayVisible || icons[i].image == nil {
                    icons[i].removeAllSymbolEffects(animated: false)
                    icons[i].image = image
                } else if (previous == tabs[i]) != (selection == tabs[i]) {
                    icons[i].setSymbolImage(image, contentTransition: .replace)
                } else {
                    icons[i].image?.accessibilityDescription = tabs[i].title
                }
            }
        }
    }

    @objc private func selectSegment() {
        guard tabs.indices.contains(control.selectedSegment) else { return }
        let tab = tabs[control.selectedSegment]
        guard tab != selection else { return }
        update(selection: tab, reduceMotion: reduceMotion)
        onSelection(tab)
    }

    override func layout() {
        super.layout()
        control.frame = bounds
        control.layoutSubtreeIfNeeded()
        refreshGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshGeometry), name: name, object: window)
            }
        }
        refreshGeometry()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshGeometry()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshGeometry()
    }

    /// Read only this control's public semantic tree, never the hosting view's private hierarchy.
    @objc private func refreshGeometry() {
        guard #available(macOS 26.0, *), let window, control.window === window,
              nativeImages.count == tabs.count else { restoreNativeImages(); return }
        let segments = Self.segments(in: control)
        guard segments.count == tabs.count else { restoreNativeImages(); return }
        var frames: [NSRect] = []
        for (i, segment) in segments.enumerated() {
            let screen = segment.accessibilityFrame()
            let frame = convert(window.convertFromScreen(screen), from: nil)
            guard (segment.accessibilityParent() as AnyObject?) === control.cell,
                  segment.accessibilityLabel() == tabs[i].title,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0, bounds.contains(frame),
                  frames.last.map({ $0.maxX <= frame.minX }) ?? true else {
                restoreNativeImages(); return
            }
            frames.append(frame)
        }
        for i in tabs.indices {
            // alignmentRect is public baseline metadata; do not assume equal division or system insets.
            let image = nativeImages[i]
            let center = NSPoint(x: frames[i].midX, y: frames[i].midY + image.size.height / 2 - image.alignmentRect.midY)
            icons[i].frame = NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
            icons[i].isHidden = false
            if !overlayVisible { control.setImage(Self.placeholder(image), forSegment: i) }
        }
        overlayVisible = true
    }

    private func restoreNativeImages() {
        overlayVisible = false
        for i in tabs.indices {
            if #available(macOS 26.0, *) { icons[i].removeAllSymbolEffects(animated: false) }
            icons[i].isHidden = true
            // Older deployments retain the existing outline-only system UI; no new fallback surface.
            let image: NSImage
            if #available(macOS 26.0, *) { image = symbol(for: tabs[i]) }
            else { image = NSImage(systemSymbolName: tabs[i].systemImage, accessibilityDescription: tabs[i].title) ?? NSImage() }
            control.setImage(image, forSegment: i)
        }
    }

    private func symbol(for tab: DashboardTab) -> NSImage {
        NSImage(systemSymbolName: tab.systemImage + (tab == selection ? ".fill" : ""), accessibilityDescription: tab.title) ?? NSImage()
    }

    private static func segments(in element: any NSAccessibilityProtocol, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 8 else { return [] }
        if element.accessibilityRole() == .radioButton { return [element] }
        return (element.accessibilityChildren() ?? []).flatMap {
            ($0 as? any NSAccessibilityProtocol).map { segments(in: $0, depth: depth + 1) } ?? []
        }
    }

    private static func placeholder(_ image: NSImage) -> NSImage {
        let blank = NSImage(size: image.size, flipped: false) { _ in true }
        blank.alignmentRect = image.alignmentRect
        blank.capInsets = image.capInsets
        blank.resizingMode = image.resizingMode
        blank.isTemplate = image.isTemplate
        blank.accessibilityDescription = image.accessibilityDescription
        return blank
    }
}

private final class DashboardTabForeground: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
