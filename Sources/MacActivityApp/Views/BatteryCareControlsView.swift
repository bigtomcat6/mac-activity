import AppKit
import SwiftUI
import MacActivityBatteryControl

struct BatteryCareControlsView: NSViewRepresentable {
    @ObservedObject var model: BatteryCareModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeNSView(context: Context) -> BatteryCareNativeControls { BatteryCareNativeControls(model: model) }
    func updateNSView(_ view: BatteryCareNativeControls, context: Context) {
        view.update(model.presentation, fontScale: dynamicTypeSize.isAccessibilitySize ? 1.5 :
            dynamicTypeSize >= .xxxLarge ? 1.25 : 1)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BatteryCareNativeControls, context: Context) -> CGSize? {
        nsView.contentSize(width: proposal.width ?? DashboardPopoverLayout.contentWidth)
    }
}

final class BatteryCareNativeControls: NSView {
    let model: BatteryCareModel
    private let mirror = NSTextField(wrappingLabelWithString: "")
    private let state = NSTextField(wrappingLabelWithString: "")
    private let current = NSTextField(wrappingLabelWithString: "")
    private let discharge = BatteryCareActionButton()
    private let fullCharge = BatteryCareActionButton()
    private let more = BatteryCareActionButton()
    private let slider = BatteryCareNativeSlider()
    private var settingsPopover: NSPopover?

    override var isFlipped: Bool { true }

    init(model: BatteryCareModel) {
        self.model = model
        super.init(frame: .zero)
        for (view, id) in [(mirror, "mirror"), (state, "state"), (current, "current"),
                           (discharge, "discharge"), (fullCharge, "fullCharge"), (more, "more")] {
            view.setAccessibilityIdentifier("batteryCare." + id)
            addSubview(view)
        }
        addSubview(slider)
        more.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        more.imagePosition = .imageOnly
        more.perform = { [weak self] in self?.showSettings() }
        discharge.nextKeyView = fullCharge
        fullCharge.nextKeyView = more
        more.nextKeyView = slider
        update(model.presentation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ p: BatteryCarePresentation, fontScale: CGFloat = 1) {
        for view in [mirror, state, current, discharge, fullCharge, more] {
            view.font = .systemFont(ofSize: NSFont.systemFontSize * fontScale)
        }
        let displayedLimit = p.previewLimit ?? p.pendingLimit
        mirror.stringValue = p.presence == .absent ? BatteryCareText.string(.batteryCareNoBattery) :
            BatteryCareText.percent(displayedLimit == nil ? .batteryCareLimit : .batteryCarePreview, displayedLimit ?? p.savedLimit)
        mirror.setAccessibilityLabel(BatteryCareText.string(.batteryCareLimitName))
        state.stringValue = BatteryCareText.status(p)
        let stop = p.stopDischarge.isEnabled
        let cancel = p.cancelFullCharge.isEnabled
        discharge.title = BatteryCareText.string(stop ? .batteryCareStopDischarge : .batteryCareDischarge)
        fullCharge.title = BatteryCareText.string(cancel ? .batteryCareCancelFullCharge : .batteryCareFullCharge)
        // Bind the action to the same presentation as its title, not a newer unrendered model.
        discharge.perform = { [weak model] in
            guard let model else { return }
            Task { if stop { await model.stopDischarge() } else { await model.startDischarge() } }
        }
        fullCharge.perform = { [weak model] in
            guard let model else { return }
            Task { if cancel { await model.cancelFullCharge() } else { await model.startFullCharge() } }
        }
        discharge.isEnabled = stop || p.startDischarge.isEnabled
        fullCharge.isEnabled = cancel || p.startFullCharge.isEnabled
        let dischargeReason = BatteryCareText.reason(p.startDischarge.disabledReason)
        let fullReason = BatteryCareText.reason(p.startFullCharge.disabledReason)
        discharge.setAccessibilityHelp(stop ? state.stringValue : dischargeReason)
        fullCharge.setAccessibilityHelp(cancel ? state.stringValue : fullReason)
        more.title = BatteryCareText.string(.batteryCareMore)
        more.toolTip = more.title
        more.setAccessibilityLabel(more.title)
        more.setAccessibilityHelp([state.stringValue, BatteryCareText.reason(p.enableManagement.disabledReason),
                                  dischargeReason, fullReason].compactMap { $0 }.joined(separator: ". "))
        if p.presence == .absent { current.stringValue = BatteryCareText.string(.batteryCareNoBattery) }
        else if let value = p.currentSystemPercentage {
            current.stringValue = String(format: BatteryCareText.string(.batteryCareCurrent), value)
        } else { current.stringValue = BatteryCareText.string(.batteryCareCurrentUnknown) }
        current.setAccessibilityLabel(BatteryCareText.string(.batteryCareCurrentName))
        slider.configure(value: displayedLimit ?? p.savedLimit, isEnabled: p.editLimit.isEnabled,
            baseline: p.pendingLimit ?? p.savedLimit,
            onPreview: { [weak model] in model?.previewLimit($0) },
            onCommit: { [weak model] in
                guard let model, let limit = model.capturePreviewCommit() else { return }
                Task { await model.commitLimit(limit) }
            },
            onCancel: { [weak model] in model?.cancelPreview() })
        slider.setAccessibilityValueDescription(mirror.stringValue + ". " + state.stringValue)
        slider.setAccessibilityHelp(BatteryCareText.reason(p.editLimit.disabledReason) ?? BatteryCareText.string(.batteryCareSliderHelp))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // Both rows grow vertically for long translations/large text; neither adds a third row nor shrinks fonts.
    func contentSize(width: CGFloat) -> NSSize {
        let widths = columnWidths(width)
        let first = max(mirrorHeight(width: widths[0]) + 4 +
            textHeight(state.stringValue, width: widths[0], font: state.font),
            textHeight(discharge.title, width: widths[1] - 16, font: discharge.font) + 16,
            textHeight(fullCharge.title, width: widths[2] - 16, font: fullCharge.font) + 16, 32)
        let second = max(24, textHeight(current.stringValue, width: width * 0.34, font: current.font))
        return NSSize(width: width, height: ceil(first + 8 + second + 24))
    }

    override var intrinsicContentSize: NSSize { contentSize(width: bounds.width > 0 ? bounds.width : 420) }

    override func layout() {
        super.layout()
        discharge.nextKeyView = fullCharge
        fullCharge.nextKeyView = more
        more.nextKeyView = slider
        let widths = columnWidths(bounds.width)
        let size = contentSize(width: bounds.width)
        let bottomHeight = max(24, textHeight(current.stringValue, width: bounds.width * 0.34, font: current.font))
        let topHeight = size.height - bottomHeight - 32
        let mirrorHeight = mirrorHeight(width: widths[0])
        mirror.frame = NSRect(x: 12, y: 12, width: widths[0], height: mirrorHeight)
        state.frame = NSRect(x: 12, y: 16 + mirrorHeight, width: widths[0], height: topHeight - mirrorHeight - 4)
        var x: CGFloat = 12 + widths[0] + 8
        discharge.frame = NSRect(x: x, y: 12, width: widths[1], height: topHeight)
        x += widths[1] + 8
        fullCharge.frame = NSRect(x: x, y: 12, width: widths[2], height: topHeight)
        x += widths[2] + 8
        more.frame = NSRect(x: x, y: 12, width: 32, height: topHeight)
        let currentWidth = bounds.width * 0.34
        slider.frame = NSRect(x: 12, y: 20 + topHeight + (bottomHeight - 24) / 2,
                              width: bounds.width - 32 - currentWidth, height: 24)
        current.frame = NSRect(x: bounds.width - 12 - currentWidth, y: 20 + topHeight,
                               width: currentWidth, height: bottomHeight)
    }

    private func columnWidths(_ width: CGFloat) -> [CGFloat] {
        let available = max(120, width - 24 - 24 - 32)
        return [available * 0.34, available * 0.30, available * 0.36]
    }

    private func mirrorHeight(width: CGFloat) -> CGFloat {
        // Reserve the longest editable label, not a guessed fixed row height.
        [mirror.stringValue, BatteryCareText.percent(.batteryCareLimit, 100),
         BatteryCareText.percent(.batteryCarePreview, 100)]
            .map { textHeight($0, width: width, font: mirror.font) }.max() ?? 0
    }

    private func textHeight(_ text: String, width: CGFloat, font: NSFont?) -> CGFloat {
        ceil((text as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).height) + 2
    }

    private func showSettings() {
        if settingsPopover?.isShown == true { settingsPopover?.performClose(nil); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: BatteryCareSettingsView(model: model))
        settingsPopover = popover
        popover.show(relativeTo: more.bounds, of: more, preferredEdge: .maxY)
    }
}
