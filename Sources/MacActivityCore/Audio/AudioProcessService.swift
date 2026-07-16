import AppKit
import CoreAudio
import Foundation

public struct AudioProcessEntry: Identifiable, Equatable, Sendable {
    public var id: AudioObjectID { processObjectID }
    public let processObjectID: AudioObjectID
    public let processIdentifier: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let outputDeviceIDs: [AudioDeviceID]

    public init(
        processObjectID: AudioObjectID,
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        bundleURL: URL?,
        outputDeviceIDs: [AudioDeviceID] = []
    ) {
        self.processObjectID = processObjectID
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.outputDeviceIDs = outputDeviceIDs
    }
}

public struct AudioProcessSnapshot: Equatable, Sendable {
    public let processObjectID: AudioObjectID
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let isRunningOutput: Bool
    public let outputDeviceIDs: [AudioDeviceID]

    public init(
        processObjectID: AudioObjectID,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        isRunningOutput: Bool,
        outputDeviceIDs: [AudioDeviceID] = []
    ) {
        self.processObjectID = processObjectID
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.isRunningOutput = isRunningOutput
        self.outputDeviceIDs = outputDeviceIDs
    }
}

public struct AudioProcessAppSnapshot: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?

    public init(
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        bundleURL: URL?
    ) {
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
    }
}

@MainActor
public protocol AudioProcessProviding: AnyObject {
    func audibleOutputProcesses() -> [AudioProcessEntry]
}

@MainActor
public final class AudioProcessService: AudioProcessProviding {
    private let availability: AudioFeatureAvailability
    private let processSnapshotReader: @MainActor @Sendable () -> [AudioProcessSnapshot]
    private let appSnapshotReader: @MainActor () -> [AudioProcessAppSnapshot]

    public init(
        workspace: NSWorkspace = .shared,
        availability: AudioFeatureAvailability = .current
    ) {
        self.availability = availability
        self.processSnapshotReader = {
            Self.readProcessSnapshotsIfAvailable(client: .system)
        }
        self.appSnapshotReader = {
            workspace.runningApplications.map {
                AudioProcessAppSnapshot(
                    processIdentifier: $0.processIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "Process \($0.processIdentifier)",
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL
                )
            }
        }
    }

    init(
        availability: AudioFeatureAvailability,
        processSnapshotReader: @escaping @MainActor @Sendable () -> [AudioProcessSnapshot],
        appSnapshotReader: @escaping @MainActor () -> [AudioProcessAppSnapshot]
    ) {
        self.availability = availability
        self.processSnapshotReader = processSnapshotReader
        self.appSnapshotReader = appSnapshotReader
    }

    public func audibleOutputProcesses() -> [AudioProcessEntry] {
        guard availability.supportsProcessControls else {
            return []
        }

        return Self.makeEntries(
            processObjects: processSnapshotReader(),
            apps: appSnapshotReader()
        )
    }

    public nonisolated static func makeEntries(
        processObjects: [AudioProcessSnapshot],
        apps: [AudioProcessAppSnapshot]
    ) -> [AudioProcessEntry] {
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })

        return processObjects
            .filter(\.isRunningOutput)
            .map { snapshot in
                let app = appsByPID[snapshot.processIdentifier]
                return AudioProcessEntry(
                    processObjectID: snapshot.processObjectID,
                    processIdentifier: snapshot.processIdentifier,
                    name: app?.name ?? snapshot.bundleIdentifier ?? "Process \(snapshot.processIdentifier)",
                    bundleIdentifier: app?.bundleIdentifier ?? snapshot.bundleIdentifier,
                    bundleURL: app?.bundleURL,
                    outputDeviceIDs: snapshot.outputDeviceIDs
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func readProcessSnapshotsIfAvailable() -> [AudioProcessSnapshot] {
        readProcessSnapshotsIfAvailable(client: .system)
    }

    static func readProcessSnapshotsIfAvailable(
        client: AudioHALClient
    ) -> [AudioProcessSnapshot] {
        if #available(macOS 14.2, *) {
            return readProcessSnapshots(client: client)
        }
        return []
    }

    static func readProcessSnapshotsIfAvailable(
        isRuntimeProcessDiscoveryAvailable: Bool = runtimeProcessDiscoveryAvailable,
        reader: @escaping @MainActor @Sendable () -> [AudioProcessSnapshot]
    ) -> [AudioProcessSnapshot] {
        guard isRuntimeProcessDiscoveryAvailable else {
            return []
        }

        return reader()
    }
}

private extension AudioProcessService {
    static var runtimeProcessDiscoveryAvailable: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    @available(macOS 14.2, *)
    static func readProcessSnapshots(
        client: AudioHALClient
    ) -> [AudioProcessSnapshot] {
        let address = AudioHALPropertyAddress(
            selector: kAudioHardwarePropertyProcessObjectList
        )
        guard let processObjectIDs = try? client.readArray(
            AudioObjectID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            address: address
        ) else {
            return []
        }

        return processObjectIDs.compactMap {
            processSnapshot(for: $0, client: client)
        }
    }

    @available(macOS 14.2, *)
    static func processSnapshot(
        for processObjectID: AudioObjectID,
        client: AudioHALClient
    ) -> AudioProcessSnapshot? {
        guard let processIdentifier = try? client.readScalar(
            pid_t.self,
            from: processObjectID,
            address: .init(selector: kAudioProcessPropertyPID)
        ) else {
            return nil
        }

        let bundleIdentifier = try? client.readRetainedString(
            from: processObjectID,
            address: .init(selector: kAudioProcessPropertyBundleID)
        )
        let isRunningOutput = ((try? client.readScalar(
            UInt32.self,
            from: processObjectID,
            address: .init(selector: kAudioProcessPropertyIsRunningOutput)
        )) ?? 0) != 0
        let outputDeviceIDs = (try? client.readArray(
            AudioDeviceID.self,
            from: processObjectID,
            address: .init(
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            )
        )) ?? []

        return AudioProcessSnapshot(
            processObjectID: processObjectID,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            isRunningOutput: isRunningOutput,
            outputDeviceIDs: outputDeviceIDs
        )
    }
}
