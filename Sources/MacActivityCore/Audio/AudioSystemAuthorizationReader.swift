import Darwin
import Foundation

public enum AudioSystemAuthorizationStatus: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    case unavailable
}

public protocol AudioSystemAuthorizationReading: Sendable {
    func authorizationStatus() async -> AudioSystemAuthorizationStatus
}

public struct AudioSystemAuthorizationReader: AudioSystemAuthorizationReading {
    private let availability: AudioFeatureAvailability
    private let rawPreflight: @Sendable () -> Int?

    public init(availability: AudioFeatureAvailability = .current) {
        self.availability = availability
        rawPreflight = {
            guard let preflight = TCCPreflight() else { return nil }
            return preflight.call()
        }
    }

    init(
        availability: AudioFeatureAvailability,
        rawPreflight: @escaping @Sendable () -> Int?
    ) {
        self.availability = availability
        self.rawPreflight = rawPreflight
    }

    /// Runs the passive TCC preflight in a detached utility task so its IPC cannot block the main actor.
    public func authorizationStatus() async -> AudioSystemAuthorizationStatus {
        guard availability.supportsProcessControls else { return .unavailable }
        let rawPreflight = rawPreflight
        return await Task.detached(priority: .utility) {
            switch rawPreflight() {
            case 0:
                .authorized
            case 1:
                .denied
            case 2:
                .notDetermined
            default:
                .unavailable
            }
        }.value
    }
}

private typealias TCCAccessPreflight = @convention(c) (CFString, CFDictionary?) -> Int

private final class TCCPreflight {
    private let handle: UnsafeMutableRawPointer
    private let preflight: TCCAccessPreflight

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC",
            RTLD_NOW
        ) else {
            return nil
        }
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        preflight = unsafeBitCast(symbol, to: TCCAccessPreflight.self)
    }

    deinit {
        dlclose(handle)
    }

    func call() -> Int {
        // Retain the dynamic library with its symbol for the duration of this call.
        preflight("kTCCServiceAudioCapture" as CFString, nil)
    }
}
