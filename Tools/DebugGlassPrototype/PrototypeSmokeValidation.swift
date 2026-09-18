import AppKit

@available(macOS 26.0, *)
@MainActor
enum PrototypeSmokeValidation {
    static let prototypeWindowIdentifierPrefix = "DebugGlassPrototype"

    static func expectedMonitorCount(for host: PrototypeHostKind) -> Int {
        switch host {
        case .popover:
            return 1
        case .panel:
            return 6
        }
    }

    static func modeFailure(mode: PrototypeMode, report: PrototypeSmokeModeReport) -> String? {
        guard let host = PrototypeHostKind(rawValue: report.effectiveHost) else {
            return "unknown-effective-host:\(mode.rawValue)"
        }

        switch host {
        case .popover:
            if report.popoverShownWhileOpen != true {
                return "popover-not-shown:\(mode.rawValue)"
            }
            if report.panelShownWhileOpen == true {
                return "unexpected-panel-host:\(mode.rawValue)"
            }
            if report.windowFrame == nil {
                return "popover-missing-frame:\(mode.rawValue)"
            }
            if report.frameWithinVisibleFrame != true {
                return "popover-outside-visible-frame:\(mode.rawValue)"
            }
            if report.monitorCountWhileOpen != expectedMonitorCount(for: .popover) {
                return "monitor-count-while-open:\(mode.rawValue)"
            }
            if report.popoverShownAfterClose != false {
                return "popover-still-shown-after-close:\(mode.rawValue)"
            }
            return nil
        case .panel:
            if report.panelShownWhileOpen != true {
                return "panel-not-shown"
            }
            if report.popoverShownWhileOpen == true {
                return "unexpected-popover-host:\(mode.rawValue)"
            }
            if report.windowFrame == nil {
                return "panel-missing-frame"
            }
            if report.frameWithinVisibleFrame != true {
                return "panel-outside-visible-frame"
            }
            if report.monitorCountWhileOpen != expectedMonitorCount(for: .panel) {
                return "monitor-count-while-open:transparent-panel"
            }
            return transparentPanelAttributeFailure(report)
        }
    }

    static func transparentPanelAttributeFailure(_ report: PrototypeSmokeModeReport) -> String? {
        if report.isOpaque != false {
            return "panel-not-transparent:isOpaque"
        }
        if report.backgroundColorClear != true {
            return "panel-not-transparent:backgroundColor"
        }
        if report.alphaValue != 1 {
            return "panel-not-transparent:alphaValue"
        }
        guard let rawStyleMask = report.styleMask else {
            return "panel-not-transparent:styleMask"
        }
        let styleMask = NSWindow.StyleMask(rawValue: rawStyleMask)
        if styleMask.isSuperset(of: [.borderless, .nonactivatingPanel]) == false {
            return "panel-not-transparent:styleMask"
        }
        if report.canBecomeKey != true {
            return "panel-not-transparent:canBecomeKey"
        }
        if report.hasShadow != false {
            return "panel-not-transparent:hasShadow"
        }
        if report.level != NSWindow.Level.popUpMenu.rawValue {
            return "panel-not-transparent:level"
        }
        return nil
    }

    static func leakedPrototypeWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { window in
            window.isVisible
                && window.identifier?.rawValue.hasPrefix(prototypeWindowIdentifierPrefix) == true
        }
    }
}
