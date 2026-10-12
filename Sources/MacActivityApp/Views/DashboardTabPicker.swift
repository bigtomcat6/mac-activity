import AppKit
import SwiftUI
import Symbols

struct DashboardTabPicker: View {
    @Binding var selection: DashboardTab
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            DashboardGlassTabPicker(selection: $selection)
        } else {
            DashboardNativeTabPicker(selection: $selection)
        }
    }
}

@available(macOS 26.0, *)
private struct DashboardGlassTabPicker: View {
    @Binding var selection: DashboardTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Namespace private var glassNamespace
    @State private var focusGroup = DashboardNavigationFocus()

    private var selectedGlass: Glass {
        contrast == .increased ? .regular.tint(.accentColor) : .regular
    }

    var body: some View {
        ZStack {
            // The track is outside the morphing container: it never merges with the lens.
            Color.clear.glassEffect(.regular, in: Capsule())
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(DashboardTab.allCases) { tab in
                        Color.clear.frame(width: 31.5, height: 28)
                            .background {
                                if selection == tab {
                                    if reduceMotion {
                                        Color.clear.glassEffect(selectedGlass, in: Capsule())
                                    } else {
                                        Color.clear
                                            .glassEffect(selectedGlass.interactive(), in: Capsule())
                                            .glassEffectID("selection", in: glassNamespace)
                                            .glassEffectTransition(.matchedGeometry)
                                            // Bridge layout across slots after the native effect; before it the lens jumps.
                                            .matchedGeometryEffect(id: "selection-frame", in: glassNamespace)
                                    }
                                }
                            }
                        }
                }
            }
            // Recreate only effect nodes to cancel an in-flight morph; retain native focus.
            .id(reduceMotion)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: selection)
            HStack(spacing: 0) {
                ForEach(DashboardTab.allCases) { tab in
                    DashboardTabButton(tab: tab, selected: selection == tab, reduceMotion: reduceMotion, focusGroup: focusGroup) { select(tab) }
                        .frame(width: 31.5, height: 28)
                }
            }
        }
        .frame(width: 126, height: 28)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }

    private func select(_ tab: DashboardTab) {
        guard tab != selection else { return }
        withTransaction(Transaction(animation: nil)) { selection = tab }
    }

}

@available(macOS 26.0, *)
private struct DashboardTabButton: NSViewRepresentable {
    var tab: DashboardTab
    var selected: Bool
    var reduceMotion: Bool
    var focusGroup: DashboardNavigationFocus
    var action: () -> Void

    func makeNSView(context: Context) -> DashboardNavigationButton {
        DashboardNavigationButton()
    }

    func updateNSView(_ button: DashboardNavigationButton, context: Context) {
        button.actionHandler = action
        focusGroup.buttons[tab] = DashboardNavigationFocus.ButtonReference(button)
        button.moveFocus = { [weak focusGroup] offset in
            let tabs = DashboardTab.allCases
            let index = tabs.firstIndex(of: tab) ?? 0
            let target = tabs[min(max(index + offset, 0), tabs.count - 1)]
            if let next = focusGroup?.buttons[target]?.button { next.window?.makeFirstResponder(next) }
        }
        button.selected = selected
        button.setAccessibilityLabel(tab.title)
        button.cell?.setAccessibilityLabel(tab.title)
        button.cell?.setAccessibilityValue(NSNumber(value: selected))
        button.toolTip = tab.title
        let view = button.icon
        let image = NSImage(systemSymbolName: tab.systemImage + (selected ? ".fill" : ""), accessibilityDescription: tab.title) ?? NSImage()
        if reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || view.image == nil {
            view.removeAllSymbolEffects(animated: false)
            view.image = image
        } else if view.image?.tiffRepresentation != image.tiffRepresentation {
            view.setSymbolImage(image, contentTransition: .replace)
        }
    }
}

private final class DashboardNavigationFocus {
    final class ButtonReference {
        weak var button: DashboardNavigationButton?
        init(_ button: DashboardNavigationButton) { self.button = button }
    }
    var buttons: [DashboardTab: ButtonReference] = [:]
}

/// A borderless native button owns input and AX; the non-hit foreground cannot intercept it.
private final class DashboardNavigationButton: NSButton {
    let icon = DashboardTabForeground()
    var selected = false
    var actionHandler: () -> Void = {}
    var moveFocus: (Int) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 31.5, height: 28) }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        target = self
        action = #selector(activate)
        setAccessibilityRole(.radioButton)
        cell?.setAccessibilityRole(.radioButton)
        icon.imageScaling = .scaleNone
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .labelColor
        icon.setAccessibilityElement(false)
        icon.setAccessibilityHidden(true)
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { actionHandler() }
    override func accessibilityValue() -> Any? { NSNumber(value: selected) }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
    override func layout() { super.layout(); icon.frame = bounds }
    override func highlight(_ flag: Bool) {
        // Let the native borderless button render its own pressed glyph, not a custom scale/opacity.
        image = flag ? icon.image : nil
        icon.isHidden = flag
        super.highlight(flag)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124:
            moveFocus(event.keyCode == 123 ? -1 : 1)
        case 49, 36, 76:
            if !event.isARepeat { performClick(nil) }
        default: super.keyDown(with: event)
        }
    }
}

/// Existing native route for older deployments and opaque accessibility presentation.
struct DashboardNativeTabPicker: NSViewRepresentable {
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
