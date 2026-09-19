import AppKit
import SwiftUI

enum DashboardGlassKind: Equatable, Sendable {
    case perCardRegular
    case rootRegular
}

enum DashboardForegroundStyle: Equatable, Sendable {
    case system
    case translucent
}

struct DashboardStyleAppearance: Equatable, Sendable {
    var glassKind: DashboardGlassKind
    var foregroundStyle: DashboardForegroundStyle
    var moduleFillOpacity: Double
    var strokeOpacity: Double
    var moduleCornerRadius: CGFloat
    var rootGlassCornerRadius: CGFloat

    var usesTranslucentChrome: Bool { foregroundStyle == .translucent }
    var usesRootGlass: Bool { glassKind == .rootRegular }
}

extension DashboardStyleAppearance {
    static var standardAppearance: DashboardStyleAppearance {
        DashboardPresentationPolicy.standardAppearance
    }
}

struct DashboardRootGlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = nil
            glass.cornerRadius = cornerRadius
            return glass
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
    }
}

private struct DashboardStyleAppearanceEnvironmentKey: EnvironmentKey {
    static var defaultValue: DashboardStyleAppearance {
        DashboardPresentationPolicy.standardAppearance
    }
}

extension EnvironmentValues {
    var dashboardStyleAppearance: DashboardStyleAppearance {
        get { self[DashboardStyleAppearanceEnvironmentKey.self] }
        set { self[DashboardStyleAppearanceEnvironmentKey.self] = newValue }
    }
}

private struct DashboardPresentationIsPresentedEnvironmentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var dashboardPresentationIsPresented: Bool {
        get { self[DashboardPresentationIsPresentedEnvironmentKey.self] }
        set { self[DashboardPresentationIsPresentedEnvironmentKey.self] = newValue }
    }
}
