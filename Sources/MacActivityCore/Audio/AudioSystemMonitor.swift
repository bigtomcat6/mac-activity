import CoreAudio
import Foundation

public enum AudioDeviceSystemChange: Hashable, Sendable {
    case nominalSampleRate
    case liveness
}

public enum AudioProcessSystemChange: Hashable, Sendable {
    case runningOutput
    case outputDevices
}

public enum AudioSystemChange: Hashable, Sendable {
    case deviceList
    case defaultOutputDevice
    case serviceRestarted
    case processList
    case device(AudioDeviceID, AudioDeviceSystemChange)
    case process(AudioObjectID, AudioProcessSystemChange)
}

public protocol AudioSystemMonitoring: AnyObject, Sendable {
    var changes: AsyncStream<Set<AudioSystemChange>> { get }

    func start() throws
    func updateObservedObjects(
        deviceIDs: Set<AudioDeviceID>,
        processObjectIDs: Set<AudioObjectID>
    ) throws
    func stop()
}

public final class AudioSystemMonitor: AudioSystemMonitoring, @unchecked Sendable {
    public let changes: AsyncStream<Set<AudioSystemChange>>

    private let hal: AudioHALClient
    private let availability: AudioFeatureAvailability
    private let queue: DispatchQueue
    private let coalescingDelay: DispatchTimeInterval
    private let continuation: AsyncStream<Set<AudioSystemChange>>.Continuation
    private let queueKey = DispatchSpecificKey<UInt8>()

    private var isStarted = false
    private var observedDeviceIDs: Set<AudioDeviceID> = []
    private var observedProcessObjectIDs: Set<AudioObjectID> = []
    private var baseTokens: [AudioHALListenerToken] = []
    private var deviceTokens: [AudioDeviceID: [AudioHALListenerToken]] = [:]
    private var processTokens: [AudioObjectID: [AudioHALListenerToken]] = [:]
    private var pendingChanges: Set<AudioSystemChange> = []
    private var pendingEmission: DispatchWorkItem?
    private var emissionGeneration = 0

    public init(
        hal: AudioHALClient = .system,
        availability: AudioFeatureAvailability = .current,
        queue: DispatchQueue = DispatchQueue(
            label: "com.how.macactivity.audio.monitor"
        ),
        coalescingDelay: DispatchTimeInterval = .milliseconds(50)
    ) {
        let stream = AsyncStream<Set<AudioSystemChange>>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
        self.hal = hal
        self.availability = availability
        self.queue = queue
        self.coalescingDelay = coalescingDelay
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        pendingEmission?.cancel()
        continuation.finish()
    }

    public func start() throws {
        try serialized {
            guard !isStarted else { return }

            let newBaseTokens = try makeBaseTokens()
            let newDeviceTokens = try makeDeviceTokenMap(for: observedDeviceIDs)
            let newProcessTokens = try makeProcessTokenMap(
                for: observedProcessObjectIDs
            )

            baseTokens = newBaseTokens
            deviceTokens = newDeviceTokens
            processTokens = newProcessTokens
            isStarted = true
        }
    }

    public func updateObservedObjects(
        deviceIDs: Set<AudioDeviceID>,
        processObjectIDs: Set<AudioObjectID>
    ) throws {
        try serialized {
            guard deviceIDs != observedDeviceIDs
                || processObjectIDs != observedProcessObjectIDs else {
                return
            }
            guard isStarted else {
                observedDeviceIDs = deviceIDs
                observedProcessObjectIDs = processObjectIDs
                return
            }

            let removedDeviceIDs = observedDeviceIDs.subtracting(deviceIDs)
            let addedDeviceIDs = deviceIDs.subtracting(observedDeviceIDs)
            let removedProcessObjectIDs = observedProcessObjectIDs.subtracting(
                processObjectIDs
            )
            let addedProcessObjectIDs = processObjectIDs.subtracting(
                observedProcessObjectIDs
            )

            let addedDeviceTokens = try makeDeviceTokenMap(for: addedDeviceIDs)
            let addedProcessTokens = try makeProcessTokenMap(
                for: addedProcessObjectIDs
            )

            for deviceID in removedDeviceIDs.sorted() {
                try cancelDeviceTokens(for: deviceID)
            }
            for processObjectID in removedProcessObjectIDs.sorted() {
                try cancelProcessTokens(for: processObjectID)
            }
            deviceTokens.merge(addedDeviceTokens) { _, new in new }
            processTokens.merge(addedProcessTokens) { _, new in new }
            observedDeviceIDs = deviceIDs
            observedProcessObjectIDs = processObjectIDs
        }
    }

    public func stop() {
        serialized {
            guard isStarted || pendingEmission != nil || !allTokens.isEmpty else {
                return
            }

            isStarted = false
            emissionGeneration += 1
            pendingEmission?.cancel()
            pendingEmission = nil
            pendingChanges.removeAll()

            let tokens = allTokens
            baseTokens.removeAll()
            deviceTokens.removeAll()
            processTokens.removeAll()
            for token in tokens {
                try? token.cancel()
            }
        }
    }
}

private extension AudioSystemMonitor {
    var allTokens: [AudioHALListenerToken] {
        baseTokens
            + deviceTokens.values.flatMap { $0 }
            + processTokens.values.flatMap { $0 }
    }

    func serialized<Result>(_ body: () throws -> Result) rethrows -> Result {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    func makeBaseTokens() throws -> [AudioHALListenerToken] {
        var tokens = [AudioHALListenerToken]()
        tokens.append(
            try makeToken(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: .init(selector: kAudioHardwarePropertyDevices),
                change: .deviceList
            )
        )
        tokens.append(
            try makeToken(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: .init(selector: kAudioHardwarePropertyDefaultOutputDevice),
                change: .defaultOutputDevice
            )
        )
        tokens.append(
            try makeToken(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: .init(selector: kAudioHardwarePropertyServiceRestarted),
                change: .serviceRestarted
            )
        )
        if #available(macOS 14.2, *), availability.supportsProcessControls {
            tokens.append(
                try makeToken(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    address: .init(selector: kAudioHardwarePropertyProcessObjectList),
                    change: .processList
                )
            )
        }
        return tokens
    }

    func makeDeviceTokenMap(
        for deviceIDs: Set<AudioDeviceID>
    ) throws -> [AudioDeviceID: [AudioHALListenerToken]] {
        var tokens: [AudioDeviceID: [AudioHALListenerToken]] = [:]
        for deviceID in deviceIDs.sorted() {
            tokens[deviceID] = try makeDeviceTokens(for: deviceID)
        }
        return tokens
    }

    func makeDeviceTokens(
        for deviceID: AudioDeviceID
    ) throws -> [AudioHALListenerToken] {
        [
            try makeToken(
                objectID: deviceID,
                address: .init(selector: kAudioDevicePropertyNominalSampleRate),
                change: .device(deviceID, .nominalSampleRate)
            ),
            try makeToken(
                objectID: deviceID,
                address: .init(selector: kAudioDevicePropertyDeviceIsAlive),
                change: .device(deviceID, .liveness)
            ),
        ]
    }

    func makeProcessTokenMap(
        for processObjectIDs: Set<AudioObjectID>
    ) throws -> [AudioObjectID: [AudioHALListenerToken]] {
        guard availability.supportsProcessControls else { return [:] }
        if #available(macOS 14.2, *) {
            var tokens: [AudioObjectID: [AudioHALListenerToken]] = [:]
            for processObjectID in processObjectIDs.sorted() {
                tokens[processObjectID] = try makeProcessTokens(
                    for: processObjectID
                )
            }
            return tokens
        }
        return [:]
    }

    @available(macOS 14.2, *)
    func makeProcessTokens(
        for processObjectID: AudioObjectID
    ) throws -> [AudioHALListenerToken] {
        [
            try makeToken(
                objectID: processObjectID,
                address: .init(
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeOutput
                ),
                change: .process(processObjectID, .outputDevices)
            ),
            try makeToken(
                objectID: processObjectID,
                address: .init(selector: kAudioProcessPropertyIsRunningOutput),
                change: .process(processObjectID, .runningOutput)
            ),
        ]
    }

    func makeToken(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        change: AudioSystemChange
    ) throws -> AudioHALListenerToken {
        let queue = queue
        return try hal.addPropertyListener(
            objectID: objectID,
            address: address,
            queue: queue
        ) { [weak self] in
            queue.async { [weak self] in
                self?.receive(change)
            }
        }
    }

    func receive(_ change: AudioSystemChange) {
        guard isStarted else { return }
        if change == .serviceRestarted {
            guard rebuildAfterServiceRestart() else { return }
        }
        pendingChanges.insert(change)
        scheduleEmissionIfNeeded()
    }

    func rebuildAfterServiceRestart() -> Bool {
        let staleTokens = allTokens
        for token in staleTokens {
            token.invalidateAfterServiceRestart()
        }
        baseTokens.removeAll()
        deviceTokens.removeAll()
        processTokens.removeAll()

        do {
            let newBaseTokens = try makeBaseTokens()
            let newDeviceTokens = try makeDeviceTokenMap(for: observedDeviceIDs)
            let newProcessTokens = try makeProcessTokenMap(
                for: observedProcessObjectIDs
            )
            baseTokens = newBaseTokens
            deviceTokens = newDeviceTokens
            processTokens = newProcessTokens
            return true
        } catch {
            return false
        }
    }

    func scheduleEmissionIfNeeded() {
        guard pendingEmission == nil else { return }
        let generation = emissionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, generation == emissionGeneration else { return }
            pendingEmission = nil
            guard isStarted, !pendingChanges.isEmpty else {
                pendingChanges.removeAll()
                return
            }
            let changes = pendingChanges
            pendingChanges.removeAll()
            continuation.yield(changes)
        }
        pendingEmission = workItem
        queue.asyncAfter(
            deadline: .now() + coalescingDelay,
            execute: workItem
        )
    }

    func cancelDeviceTokens(for deviceID: AudioDeviceID) throws {
        guard let tokens = deviceTokens[deviceID] else { return }
        for token in tokens {
            try token.cancel()
        }
        deviceTokens[deviceID] = nil
    }

    func cancelProcessTokens(for processObjectID: AudioObjectID) throws {
        guard let tokens = processTokens[processObjectID] else { return }
        for token in tokens {
            try token.cancel()
        }
        processTokens[processObjectID] = nil
    }
}
