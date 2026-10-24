import AppKit
import SwiftUI

struct BatteryCareLimitSlider: NSViewRepresentable {
    @Binding var value: Int
    let isEnabled: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> BatteryCareNativeSlider { BatteryCareNativeSlider() }

    func updateNSView(_ slider: BatteryCareNativeSlider, context: Context) {
        slider.configure(value: value, isEnabled: isEnabled,
            onPreview: { value = $0 }, onCommit: onCommit, onCancel: onCancel)
    }
}

/// Native tracking owns the mouse gesture; keyboard editing and AX actions have explicit boundaries.
final class BatteryCareNativeSlider: NSSlider {
    private var onPreview: (Int) -> Void = { _ in }
    private var onCommit: () -> Void = {}
    private var onCancel: () -> Void = {}
    private var accessibilityCommitScheduled = false
    private var editing = false
    private var editingBaseline = 80
    private var mouseTracking = false
    private var mouseTrackingCancelled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minValue = 50
        maxValue = 100
        isContinuous = true
        target = self
        action = #selector(previewChanged)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityIdentifier("batteryCare.limit")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override func accessibilityValue() -> Any? { NSNumber(value: integerValue) }

    func configure(value: Int, isEnabled: Bool, baseline: Int? = nil, onPreview: @escaping (Int) -> Void,
                   onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onPreview = onPreview
        self.onCommit = onCommit
        self.onCancel = onCancel
        integerValue = value
        if let baseline { editingBaseline = baseline }
        else if !editing { editingBaseline = value }
        self.isEnabled = isEnabled
        if !isEnabled { accessibilityCommitScheduled = false; editing = false }
        setAccessibilityLabel(AppLocalization.string(.batteryCareLimitName))
        setAccessibilityHelp(AppLocalization.string(.batteryCareSliderHelp))
    }

    @objc private func previewChanged() {
        guard !mouseTrackingCancelled else { integerValue = editingBaseline; return }
        integerValue = min(100, max(50, Int(doubleValue.rounded())))
        editing = true
        onPreview(integerValue)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, event.type == .leftMouseDown, let trackingWindow = window,
              event.windowNumber == trackingWindow.windowNumber else { return }
        accessibilityCommitScheduled = false
        mouseTracking = true
        mouseTrackingCancelled = false
        defer { mouseTracking = false; mouseTrackingCancelled = false }
        super.mouseDown(with: event)
        // Native tracking can return without consuming up (even stopTracking's flag can be true).
        guard !mouseTrackingCancelled, isEnabled, trackingWindow.isVisible,
              window === trackingWindow, !isHiddenOrHasHiddenAncestor,
              let end = NSApp.currentEvent, end.type == .leftMouseUp,
              end.windowNumber == event.windowNumber, end.buttonNumber == event.buttonNumber,
              end.timestamp >= event.timestamp else { cancelEditing(); return }
        commitEditing()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.keyCode {
        case 123, 125: adjust(-1)
        case 124, 126: adjust(1)
        case 36, 76: commitEditing()
        case 53:
            mouseTrackingCancelled = mouseTracking
            cancelEditing()
        default: super.keyDown(with: event)
        }
    }

    private func adjust(_ delta: Int) {
        integerValue = min(100, max(50, integerValue + delta))
        previewChanged()
    }

    private func commitEditing() {
        accessibilityCommitScheduled = false
        guard editing else { return }
        editing = false
        editingBaseline = integerValue
        onCommit()
    }

    private func cancelEditing() {
        accessibilityCommitScheduled = false
        let wasEditing = editing
        editing = false
        integerValue = editingBaseline
        if wasEditing { onCancel() }
    }

    override func accessibilityPerformIncrement() -> Bool { accessibilityAdjust(1) }
    override func accessibilityPerformDecrement() -> Bool { accessibilityAdjust(-1) }

    private func accessibilityAdjust(_ delta: Int) -> Bool {
        guard isEnabled else { return false }
        adjust(delta)
        guard !accessibilityCommitScheduled else { return true }
        accessibilityCommitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.accessibilityCommitScheduled, self.isEnabled else { return }
            self.commitEditing()
        }
        return true
    }
}
