import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

public protocol LaunchAtLoginServicing: Sendable {
    func setEnabled(_ enabled: Bool) throws
    func currentStatus() -> Bool
}

public struct NoopLaunchAtLoginService: LaunchAtLoginServicing {
    public init() {}

    public func setEnabled(_ enabled: Bool) throws {}

    public func currentStatus() -> Bool {
        false
    }
}

#if canImport(ServiceManagement)
public final class SMAppServiceLaunchAtLoginService: LaunchAtLoginServicing, @unchecked Sendable {
    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func currentStatus() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}
#endif
