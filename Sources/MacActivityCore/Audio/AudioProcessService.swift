import AppKit
import CoreAudio
import Darwin
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

private struct AudioProcessResolvedBundleMetadata: Sendable {
    let name: String?
    let bundleURL: URL
}

@MainActor
public protocol AudioProcessProviding: AnyObject {
    var discoveredProcessObjectIDs: Set<AudioObjectID> { get }

    func audibleOutputProcesses() -> [AudioProcessEntry]
}

@MainActor
public final class AudioProcessService: AudioProcessProviding {
    private let availability: AudioFeatureAvailability
    private let processSnapshotReader: @MainActor @Sendable () -> [AudioProcessSnapshot]
    private let appSnapshotReader: @MainActor () -> [AudioProcessAppSnapshot]
    private let applicationURLReader: @MainActor (String) -> URL?
    private let processExecutableURLReader: @MainActor (pid_t) -> URL?
    private var cachedDiscoveredProcessObjectIDs: Set<AudioObjectID> = []

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
                    name: $0.localizedName ?? "",
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL
                )
            }
        }
        self.applicationURLReader = {
            workspace.urlForApplication(withBundleIdentifier: $0)
        }
        self.processExecutableURLReader = { processIdentifier in
            Self.executableURL(for: processIdentifier)
        }
    }

    init(
        availability: AudioFeatureAvailability,
        processSnapshotReader: @escaping @MainActor @Sendable () -> [AudioProcessSnapshot],
        appSnapshotReader: @escaping @MainActor () -> [AudioProcessAppSnapshot],
        applicationURLReader: @escaping @MainActor (String) -> URL? = { _ in nil },
        processExecutableURLReader: @escaping @MainActor (pid_t) -> URL? = { _ in nil }
    ) {
        self.availability = availability
        self.processSnapshotReader = processSnapshotReader
        self.appSnapshotReader = appSnapshotReader
        self.applicationURLReader = applicationURLReader
        self.processExecutableURLReader = processExecutableURLReader
    }

    public func audibleOutputProcesses() -> [AudioProcessEntry] {
        guard availability.supportsProcessControls else {
            cachedDiscoveredProcessObjectIDs = []
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let snapshots = processSnapshotReader().filter {
            $0.processIdentifier != ownPID
        }
        cachedDiscoveredProcessObjectIDs = Set(snapshots.map(\.processObjectID))
        let apps = appSnapshotReader()
        return Self.makeEntries(
            processObjects: snapshots,
            apps: apps,
            resolvedBundleMetadata: resolvedBundleMetadata(for: snapshots, apps: apps)
        )
    }

    public var discoveredProcessObjectIDs: Set<AudioObjectID> {
        cachedDiscoveredProcessObjectIDs
    }

    public nonisolated static func makeEntries(
        processObjects: [AudioProcessSnapshot],
        apps: [AudioProcessAppSnapshot]
    ) -> [AudioProcessEntry] {
        makeEntries(processObjects: processObjects, apps: apps, resolvedBundleMetadata: [:])
    }

    private nonisolated static func makeEntries(
        processObjects: [AudioProcessSnapshot],
        apps: [AudioProcessAppSnapshot],
        resolvedBundleMetadata: [pid_t: AudioProcessResolvedBundleMetadata]
    ) -> [AudioProcessEntry] {
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })

        return processObjects
            .filter(\.isRunningOutput)
            .map { snapshot in
                let app = appsByPID[snapshot.processIdentifier]
                let workspaceName = Self.readableName(app?.name)
                let resolvedBundle = resolvedBundleMetadata[snapshot.processIdentifier]
                let bundleURL = app?.bundleURL ?? resolvedBundle?.bundleURL
                return AudioProcessEntry(
                    processObjectID: snapshot.processObjectID,
                    processIdentifier: snapshot.processIdentifier,
                    name: workspaceName
                        ?? Self.readableName(resolvedBundle?.name)
                        ?? Self.readableName(bundleURL?.deletingPathExtension().lastPathComponent)
                        ?? Self.readableName(snapshot.bundleIdentifier)
                        ?? Self.readableName(app?.bundleIdentifier)
                        ?? "Process \(snapshot.processIdentifier)",
                    bundleIdentifier: app?.bundleIdentifier ?? snapshot.bundleIdentifier,
                    bundleURL: bundleURL,
                    outputDeviceIDs: snapshot.outputDeviceIDs
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func resolvedBundleMetadata(
        for processObjects: [AudioProcessSnapshot],
        apps: [AudioProcessAppSnapshot]
    ) -> [pid_t: AudioProcessResolvedBundleMetadata] {
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })

        return processObjects
            .filter(\.isRunningOutput)
            .reduce(into: [:]) { metadata, snapshot in
                guard metadata[snapshot.processIdentifier] == nil else { return }

                let app = appsByPID[snapshot.processIdentifier]
                let workspaceName = Self.readableName(app?.name)
                guard workspaceName == nil || app?.bundleURL == nil else { return }

                let workspaceOrBundleIdentifierBundle: Bundle?
                if let runningBundleURL = app?.bundleURL {
                    workspaceOrBundleIdentifierBundle = Bundle(url: runningBundleURL)
                } else if let bundleIdentifier = Self.readableName(snapshot.bundleIdentifier)
                    ?? Self.readableName(app?.bundleIdentifier),
                          let resolvedBundleURL = applicationURLReader(bundleIdentifier) {
                    workspaceOrBundleIdentifierBundle = Bundle(url: resolvedBundleURL)
                } else {
                    workspaceOrBundleIdentifierBundle = nil
                }
                let bundle = workspaceOrBundleIdentifierBundle
                    ?? processExecutableURLReader(snapshot.processIdentifier).flatMap {
                        Self.containingApplicationBundle(for: $0)
                    }
                guard let bundle else { return }
                let name = Self.readableName(
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ) ?? Self.readableName(
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                )
                metadata[snapshot.processIdentifier] = AudioProcessResolvedBundleMetadata(
                    name: name,
                    bundleURL: bundle.bundleURL
                )
            }
    }

    private nonisolated static func executableURL(for processIdentifier: pid_t) -> URL? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBufferPointer {
            proc_pidpath(processIdentifier, $0.baseAddress, UInt32($0.count))
        }
        guard result > 0 else { return nil }
        return path.withUnsafeBufferPointer {
            guard let baseAddress = $0.baseAddress else { return nil }
            return URL(fileURLWithPath: String(cString: baseAddress))
        }
    }

    private nonisolated static func containingApplicationBundle(
        for executableURL: URL
    ) -> Bundle? {
        guard executableURL.isFileURL else { return nil }
        var candidateURL = executableURL.standardizedFileURL
        var containingBundle: Bundle?
        while candidateURL.path != "/" {
            if candidateURL.pathExtension.lowercased() == "app",
               let bundle = Bundle(url: candidateURL) {
                containingBundle = bundle
            }
            candidateURL.deleteLastPathComponent()
        }
        return containingBundle
    }

    private nonisolated static func readableName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
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

extension AudioProcessService {
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
    nonisolated static func processSnapshot(
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
