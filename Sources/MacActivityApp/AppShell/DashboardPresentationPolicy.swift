import AppKit
import Combine
import MacActivityCore

enum DashboardPresentationHostKind: Equatable, Sendable {
    case popover
    case panel
}

struct DashboardPresentationAccessibilityEnvironment: Equatable, Sendable {
    var reduceTransparency: Bool
    var increaseContrast: Bool
    var majorVersion: Int

    static func live(
        workspace: NSWorkspace = .shared,
        processInfo: ProcessInfo = .processInfo
    ) -> DashboardPresentationAccessibilityEnvironment {
        DashboardPresentationAccessibilityEnvironment(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            majorVersion: processInfo.operatingSystemVersion.majorVersion
        )
    }
}

struct DashboardPresentationResolution: Equatable, Sendable {
    var requestedStyle: DashboardStyle
    var effectiveStyle: DashboardStyle
    var hostKind: DashboardPresentationHostKind
    var appearance: DashboardStyleAppearance
}

enum DashboardPresentationPolicy {
    static let defaultStrokeOpacity: Double = 0.16
    static let increasedContrastStrokeOpacity: Double = 0.42
    static let translucentModuleFillOpacity: Double = 0.08
    static let translucentModuleFillOpacityIncreasedContrast: Double = 0.14
    static let standardModuleCornerRadius: CGFloat = 12
    static let translucentModuleCornerRadius: CGFloat = 16
    static let rootGlassCornerRadius: CGFloat = 24

    static var standardAppearance: DashboardStyleAppearance {
        DashboardStyleAppearance(
            glassKind: .perCardRegular,
            foregroundStyle: .system,
            moduleFillOpacity: 0,
            strokeOpacity: defaultStrokeOpacity,
            moduleCornerRadius: standardModuleCornerRadius,
            rootGlassCornerRadius: rootGlassCornerRadius
        )
    }

    static func translucentAppearance(
        moduleFillOpacity: Double,
        strokeOpacity: Double
    ) -> DashboardStyleAppearance {
        DashboardStyleAppearance(
            glassKind: .rootRegular,
            foregroundStyle: .translucent,
            moduleFillOpacity: moduleFillOpacity,
            strokeOpacity: strokeOpacity,
            moduleCornerRadius: translucentModuleCornerRadius,
            rootGlassCornerRadius: rootGlassCornerRadius
        )
    }

    static func isSupported(majorVersion: Int) -> Bool {
        DashboardStyle.isTransparentSupported(majorVersion: majorVersion)
    }

    static func resolve(
        style: DashboardStyle,
        environment: DashboardPresentationAccessibilityEnvironment
    ) -> DashboardPresentationResolution {
        let strokeOpacity = environment.increaseContrast
            ? increasedContrastStrokeOpacity
            : defaultStrokeOpacity
        let standardAppearance = DashboardStyleAppearance(
            glassKind: .perCardRegular,
            foregroundStyle: .system,
            moduleFillOpacity: 0,
            strokeOpacity: strokeOpacity,
            moduleCornerRadius: standardModuleCornerRadius,
            rootGlassCornerRadius: rootGlassCornerRadius
        )

        switch style {
        case .standard:
            return DashboardPresentationResolution(
                requestedStyle: .standard,
                effectiveStyle: .standard,
                hostKind: .popover,
                appearance: standardAppearance
            )
        case .transparent:
            guard isSupported(majorVersion: environment.majorVersion),
                  !environment.reduceTransparency else {
                return DashboardPresentationResolution(
                    requestedStyle: .transparent,
                    effectiveStyle: .standard,
                    hostKind: .popover,
                    appearance: standardAppearance
                )
            }
            return DashboardPresentationResolution(
                requestedStyle: .transparent,
                effectiveStyle: .transparent,
                hostKind: .panel,
                appearance: translucentAppearance(
                    moduleFillOpacity: environment.increaseContrast
                        ? translucentModuleFillOpacityIncreasedContrast
                        : translucentModuleFillOpacity,
                    strokeOpacity: strokeOpacity
                )
            )
        }
    }
}

@MainActor
final class DashboardPresentationState: ObservableObject {
    @Published private(set) var resolution: DashboardPresentationResolution
    @Published private(set) var isPresented: Bool
    private var dashboardStyle: DashboardStyle
    private var environment: DashboardPresentationAccessibilityEnvironment

    init(
        style: DashboardStyle,
        environment: DashboardPresentationAccessibilityEnvironment
    ) {
        self.dashboardStyle = style
        self.environment = environment
        self.resolution = DashboardPresentationPolicy.resolve(style: style, environment: environment)
        self.isPresented = false
    }

    func apply(
        style: DashboardStyle?,
        environment: DashboardPresentationAccessibilityEnvironment
    ) {
        if let style {
            self.dashboardStyle = style
        }
        self.environment = environment
        let next = DashboardPresentationPolicy.resolve(style: dashboardStyle, environment: environment)
        guard next != resolution else { return }
        resolution = next
    }

    func setPresented(_ isPresented: Bool) {
        guard self.isPresented != isPresented else { return }
        self.isPresented = isPresented
    }
}
