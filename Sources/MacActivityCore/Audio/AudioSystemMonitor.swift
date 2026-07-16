import AudioToolbox
import CoreAudio
import Foundation

struct AudioRestartRecoveryBackoff: Sendable {
    private let initialDelayMilliseconds: Int
    private let maximumDelayMilliseconds: Int
    private var nextDelayMilliseconds: Int

    init(
        initialDelayMilliseconds: Int = 250,
        maximumDelayMilliseconds: Int = 4_000
    ) {
        precondition(initialDelayMilliseconds > 0)
        precondition(maximumDelayMilliseconds >= initialDelayMilliseconds)
        self.initialDelayMilliseconds = initialDelayMilliseconds
        self.maximumDelayMilliseconds = maximumDelayMilliseconds
        nextDelayMilliseconds = initialDelayMilliseconds
    }

    mutating func nextDelay() -> DispatchTimeInterval {
        let delay = nextDelayMilliseconds
        let doubled = nextDelayMilliseconds.multipliedReportingOverflow(by: 2)
        nextDelayMilliseconds = doubled.overflow
            ? maximumDelayMilliseconds
            : min(maximumDelayMilliseconds, doubled.partialValue)
        return .milliseconds(delay)
    }

    mutating func reset() {
        nextDelayMilliseconds = initialDelayMilliseconds
    }
}

public enum AudioDeviceSystemChange: Hashable, Sendable {
    case nominalSampleRate
    case liveness
    case volume
    case mute
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
    private var listenerGenerationCounter: UInt64 = 0
    private var currentListenerGeneration: UInt64?
    private var observedDeviceIDs: Set<AudioDeviceID> = []
    private var observedProcessObjectIDs: Set<AudioObjectID> = []
    private var baseTokens: [AudioHALListenerToken] = []
    private var deviceTokens: [AudioDeviceID: [AudioHALListenerToken]] = [:]
    private var processTokens: [AudioObjectID: [AudioHALListenerToken]] = [:]
    private var pendingChanges: Set<AudioSystemChange> = []
    private var pendingEmission: DispatchWorkItem?
    private var restartRecoveryWorkItem: DispatchWorkItem?
    private var restartRecoveryGeneration: UInt64 = 0
    private var isRecoveringFromServiceRestart = false
    private var restartRecoveryBackoff: AudioRestartRecoveryBackoff
    private var emissionGeneration = 0

    public convenience init(
        hal: AudioHALClient = .system,
        availability: AudioFeatureAvailability = .current,
        queue: DispatchQueue = DispatchQueue(
            label: "com.how.macactivity.audio.monitor"
        ),
        coalescingDelay: DispatchTimeInterval = .milliseconds(50)
    ) {
        self.init(
            hal: hal,
            availability: availability,
            queue: queue,
            coalescingDelay: coalescingDelay,
            restartRecoveryBackoff: AudioRestartRecoveryBackoff()
        )
    }

    init(
        hal: AudioHALClient,
        availability: AudioFeatureAvailability,
        queue: DispatchQueue,
        coalescingDelay: DispatchTimeInterval,
        restartRecoveryBackoff: AudioRestartRecoveryBackoff
    ) {
        let stream = AsyncStream<Set<AudioSystemChange>>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
        self.hal = hal
        self.availability = availability
        self.queue = queue
        self.coalescingDelay = coalescingDelay
        self.restartRecoveryBackoff = restartRecoveryBackoff
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        pendingEmission?.cancel()
        restartRecoveryWorkItem?.cancel()
        continuation.finish()
    }

    public func start() throws {
        try serialized {
            guard !isStarted else {
                retryServiceRestartRecoveryNowIfNeeded()
                return
            }

            restartRecoveryBackoff.reset()
            let listenerGeneration = nextListenerGeneration()
            let newBaseTokens = try makeBaseTokens(
                listenerGeneration: listenerGeneration
            )
            let newDeviceTokens = try makeDeviceTokenMap(
                for: observedDeviceIDs,
                listenerGeneration: listenerGeneration
            )
            let newProcessTokens = try makeProcessTokenMap(
                for: observedProcessObjectIDs,
                listenerGeneration: listenerGeneration
            )

            baseTokens = newBaseTokens
            deviceTokens = newDeviceTokens
            processTokens = newProcessTokens
            currentListenerGeneration = listenerGeneration
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
            guard isStarted,
                  !isRecoveringFromServiceRestart,
                  let listenerGeneration = currentListenerGeneration else {
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

            let addedDeviceTokens = try makeDeviceTokenMap(
                for: addedDeviceIDs,
                listenerGeneration: listenerGeneration
            )
            let addedProcessTokens = try makeProcessTokenMap(
                for: addedProcessObjectIDs,
                listenerGeneration: listenerGeneration
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
            isRecoveringFromServiceRestart = false
            currentListenerGeneration = nil
            restartRecoveryBackoff.reset()
            emissionGeneration += 1
            pendingEmission?.cancel()
            pendingEmission = nil
            cancelRestartRecoveryWorkItem()
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

    func makeBaseTokens(
        listenerGeneration: UInt64
    ) throws -> [AudioHALListenerToken] {
        var tokens = [AudioHALListenerToken]()
        tokens.append(
            try makeToken(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: .init(selector: kAudioHardwarePropertyDevices),
                change: .deviceList,
                listenerGeneration: listenerGeneration
            )
        )
        tokens.append(
            try makeToken(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: .init(selector: kAudioHardwarePropertyDefaultOutputDevice),
                change: .defaultOutputDevice,
                listenerGeneration: listenerGeneration
            )
        )
        tokens.append(
            try makeToken(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: .init(selector: kAudioHardwarePropertyServiceRestarted),
                change: .serviceRestarted,
                listenerGeneration: listenerGeneration
            )
        )
        if #available(macOS 14.2, *), availability.supportsProcessControls {
            tokens.append(
                try makeToken(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    address: .init(selector: kAudioHardwarePropertyProcessObjectList),
                    change: .processList,
                    listenerGeneration: listenerGeneration
                )
            )
        }
        return tokens
    }

    func makeDeviceTokenMap(
        for deviceIDs: Set<AudioDeviceID>,
        listenerGeneration: UInt64
    ) throws -> [AudioDeviceID: [AudioHALListenerToken]] {
        var tokens: [AudioDeviceID: [AudioHALListenerToken]] = [:]
        for deviceID in deviceIDs.sorted() {
            tokens[deviceID] = try makeDeviceTokens(
                for: deviceID,
                listenerGeneration: listenerGeneration
            )
        }
        return tokens
    }

    func makeDeviceTokens(
        for deviceID: AudioDeviceID,
        listenerGeneration: UInt64
    ) throws -> [AudioHALListenerToken] {
        var tokens = [
            try makeToken(
                objectID: deviceID,
                address: .init(selector: kAudioDevicePropertyNominalSampleRate),
                change: .device(deviceID, .nominalSampleRate),
                listenerGeneration: listenerGeneration
            ),
            try makeToken(
                objectID: deviceID,
                address: .init(selector: kAudioDevicePropertyDeviceIsAlive),
                change: .device(deviceID, .liveness),
                listenerGeneration: listenerGeneration
            ),
        ]
        let volumeAddress = AudioHALPropertyAddress(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
        if hal.hasProperty(objectID: deviceID, address: volumeAddress) {
            tokens.append(
                try makeToken(
                    objectID: deviceID,
                    address: volumeAddress,
                    change: .device(deviceID, .volume),
                    listenerGeneration: listenerGeneration
                )
            )
        }
        let muteAddress = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        )
        if hal.hasProperty(objectID: deviceID, address: muteAddress) {
            tokens.append(
                try makeToken(
                    objectID: deviceID,
                    address: muteAddress,
                    change: .device(deviceID, .mute),
                    listenerGeneration: listenerGeneration
                )
            )
        }
        return tokens
    }

    func makeProcessTokenMap(
        for processObjectIDs: Set<AudioObjectID>,
        listenerGeneration: UInt64
    ) throws -> [AudioObjectID: [AudioHALListenerToken]] {
        guard availability.supportsProcessControls else { return [:] }
        if #available(macOS 14.2, *) {
            var tokens: [AudioObjectID: [AudioHALListenerToken]] = [:]
            for processObjectID in processObjectIDs.sorted() {
                tokens[processObjectID] = try makeProcessTokens(
                    for: processObjectID,
                    listenerGeneration: listenerGeneration
                )
            }
            return tokens
        }
        return [:]
    }

    @available(macOS 14.2, *)
    func makeProcessTokens(
        for processObjectID: AudioObjectID,
        listenerGeneration: UInt64
    ) throws -> [AudioHALListenerToken] {
        [
            try makeToken(
                objectID: processObjectID,
                address: .init(
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeOutput
                ),
                change: .process(processObjectID, .outputDevices),
                listenerGeneration: listenerGeneration
            ),
            try makeToken(
                objectID: processObjectID,
                address: .init(selector: kAudioProcessPropertyIsRunningOutput),
                change: .process(processObjectID, .runningOutput),
                listenerGeneration: listenerGeneration
            ),
        ]
    }

    func makeToken(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        change: AudioSystemChange,
        listenerGeneration: UInt64
    ) throws -> AudioHALListenerToken {
        let queue = queue
        return try hal.addPropertyListener(
            objectID: objectID,
            address: address,
            queue: queue
        ) { [weak self] in
            queue.async { [weak self] in
                self?.receive(
                    change,
                    listenerGeneration: listenerGeneration
                )
            }
        }
    }

    func receive(
        _ change: AudioSystemChange,
        listenerGeneration: UInt64
    ) {
        guard isStarted,
              currentListenerGeneration == listenerGeneration else {
            return
        }
        if change == .serviceRestarted {
            beginServiceRestartRecovery()
            return
        }
        pendingChanges.insert(change)
        scheduleEmissionIfNeeded()
    }

    func beginServiceRestartRecovery() {
        isRecoveringFromServiceRestart = true
        currentListenerGeneration = nil
        restartRecoveryBackoff.reset()
        cancelRestartRecoveryWorkItem()
        let staleTokens = allTokens
        for token in staleTokens {
            token.invalidateAfterServiceRestart()
        }
        baseTokens.removeAll()
        deviceTokens.removeAll()
        processTokens.removeAll()

        attemptServiceRestartRecovery()
    }

    func attemptServiceRestartRecovery() {
        guard isStarted, isRecoveringFromServiceRestart else { return }
        let listenerGeneration = nextListenerGeneration()
        do {
            let newBaseTokens = try makeBaseTokens(
                listenerGeneration: listenerGeneration
            )
            let newDeviceTokens = try makeDeviceTokenMap(
                for: observedDeviceIDs,
                listenerGeneration: listenerGeneration
            )
            let newProcessTokens = try makeProcessTokenMap(
                for: observedProcessObjectIDs,
                listenerGeneration: listenerGeneration
            )
            baseTokens = newBaseTokens
            deviceTokens = newDeviceTokens
            processTokens = newProcessTokens
            currentListenerGeneration = listenerGeneration
            isRecoveringFromServiceRestart = false
            restartRecoveryBackoff.reset()
            cancelRestartRecoveryWorkItem()
            pendingChanges.insert(.serviceRestarted)
            scheduleEmissionIfNeeded()
        } catch {
            scheduleServiceRestartRecovery()
        }
    }

    func scheduleServiceRestartRecovery() {
        guard isStarted,
              isRecoveringFromServiceRestart,
              restartRecoveryWorkItem == nil else {
            return
        }
        let generation = emissionGeneration
        let delay = restartRecoveryBackoff.nextDelay()
        restartRecoveryGeneration &+= 1
        let recoveryGeneration = restartRecoveryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == emissionGeneration,
                  recoveryGeneration == restartRecoveryGeneration,
                  isStarted,
                  isRecoveringFromServiceRestart else {
                return
            }
            restartRecoveryWorkItem = nil
            attemptServiceRestartRecovery()
        }
        restartRecoveryWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    func retryServiceRestartRecoveryNowIfNeeded() {
        guard isRecoveringFromServiceRestart else { return }
        cancelRestartRecoveryWorkItem()
        attemptServiceRestartRecovery()
    }

    func cancelRestartRecoveryWorkItem() {
        restartRecoveryGeneration &+= 1
        restartRecoveryWorkItem?.cancel()
        restartRecoveryWorkItem = nil
    }

    func nextListenerGeneration() -> UInt64 {
        listenerGenerationCounter &+= 1
        return listenerGenerationCounter
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
