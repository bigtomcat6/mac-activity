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
        self.processSnapshotReader = Self.readProcessSnapshotsIfAvailable
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

    static func readProcessSnapshotsIfAvailable(
    ) -> [AudioProcessSnapshot] {
        readProcessSnapshotsIfAvailable(
            isRuntimeProcessDiscoveryAvailable: runtimeProcessDiscoveryAvailable,
            reader: readProcessSnapshots
        )
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

    static func readProcessSnapshots() -> [AudioProcessSnapshot] {
        let address = propertyAddress(
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )

        guard let processObjectIDs = getArray(
            for: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            as: AudioObjectID.self
        ) else {
            return []
        }

        return processObjectIDs.compactMap(processSnapshot)
    }

    static func processSnapshot(for processObjectID: AudioObjectID) -> AudioProcessSnapshot? {
        guard let processIdentifier = getPID(
            for: processObjectID,
            address: propertyAddress(
                selector: kAudioProcessPropertyPID,
                scope: kAudioObjectPropertyScopeGlobal
            )
        ) else {
            return nil
        }

        let bundleIdentifier = getRetainedCFString(
            for: processObjectID,
            address: propertyAddress(
                selector: kAudioProcessPropertyBundleID,
                scope: kAudioObjectPropertyScopeGlobal
            )
        ) as String?

        let isRunningOutput = getUInt32(
            for: processObjectID,
            address: propertyAddress(
                selector: kAudioProcessPropertyIsRunningOutput,
                scope: kAudioObjectPropertyScopeGlobal
            )
        ).map { $0 != 0 } ?? false

        let outputDeviceIDs = getArray(
            for: processObjectID,
            address: propertyAddress(
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            ),
            as: AudioDeviceID.self
        ) ?? []

        return AudioProcessSnapshot(
            processObjectID: processObjectID,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            isRunningOutput: isRunningOutput,
            outputDeviceIDs: outputDeviceIDs
        )
    }

    static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func getArray<T>(
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as type: T.Type
    ) -> [T]? {
        var address = address
        var byteCount: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteCount) == noErr else {
            return nil
        }

        let count = Int(byteCount) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, buffer) == noErr else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    static func getPID(
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> pid_t? {
        var address = address
        var value = pid_t.zero
        var byteCount = UInt32(MemoryLayout<pid_t>.size)

        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }

        return value
    }

    static func getUInt32(
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> UInt32? {
        var address = address
        var value = UInt32.zero
        var byteCount = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }

        return value
    }

    static func getRetainedCFString(
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> String? {
        var address = address
        let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        pointer.initialize(to: nil)
        defer { pointer.deinitialize(count: 1) }
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, pointer) == noErr,
              let value = pointer.pointee?.takeRetainedValue() else {
            return nil
        }

        return value as String
    }
}
