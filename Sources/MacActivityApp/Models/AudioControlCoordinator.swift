import Combine
import CoreAudio
import MacActivityCore

enum AudioControlUserError: Equatable, Sendable {
    case deviceRead(AudioHALError)
    case deviceWrite
    case permissionDenied
    case targetUnavailable([String])
    case routePlanning(AudioRoutePlanningError)
    case operationFailed(ProcessTapEngineError)
    case persistenceFailed
}

struct AudioDeviceControlSnapshot: Identifiable, Equatable, Sendable {
    var id: String { device.id }
    var device: AudioOutputDeviceSnapshot
    var error: AudioControlUserError?
}

struct AudioRouteDeviceOption: Identifiable, Equatable, Sendable {
    var id: String { uid }
    let uid: String
    let name: String
    let isAvailable: Bool
    let isSelected: Bool
    let isEnabled: Bool

    init(
        uid: String,
        name: String,
        isAvailable: Bool,
        isSelected: Bool,
        isEnabled: Bool = true
    ) {
        self.uid = uid
        self.name = name
        self.isAvailable = isAvailable
        self.isSelected = isSelected
        self.isEnabled = isEnabled
    }
}

struct AudioProcessControlValues: Equatable, Sendable {
    var volume: Double
    var isMuted: Bool
    var route: AudioRouteMode

    static let `default` = AudioProcessControlValues(
        volume: 1,
        isMuted: false,
        route: .followOriginal
    )

    var isDefault: Bool {
        volume == 1 && isMuted == false && route == .followOriginal
    }
}

struct AudioEffectiveVolumeState: Equatable, Sendable {
    let rawVolume: Double
    let isMuted: Bool

    init(rawVolume: Double, isMuted: Bool) {
        self.rawVolume = Self.clamped(rawVolume)
        self.isMuted = isMuted
    }

    var displayVolume: Double { isMuted || rawVolume == 0 ? 0 : rawVolume }
    var showsMutedIcon: Bool { displayVolume == 0 }
    var canRestore: Bool { rawVolume > 0 }

    func settingDisplayVolume(_ value: Double) -> Self {
        let requested = Self.clamped(value)
        return requested == 0
            ? Self(rawVolume: rawVolume, isMuted: true)
            : Self(rawVolume: requested, isMuted: false)
    }

    func settingMuted(_ muted: Bool) -> Self? {
        if muted { return Self(rawVolume: rawVolume, isMuted: true) }
        guard canRestore else { return nil }
        return Self(rawVolume: rawVolume, isMuted: false)
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 1))
    }
}

struct AudioProcessControlSnapshot: Identifiable, Equatable, Sendable {
    var id: AudioObjectID { process.processObjectID }
    let process: AudioProcessEntry
    var volume: Double
    var isMuted: Bool
    var route: AudioRouteMode
    var pendingValues: AudioProcessControlValues?
    var routeOptions: [AudioRouteDeviceOption]
    var session: ProcessTapSessionSnapshot
    var error: AudioControlUserError?
}

struct AudioControlSnapshot: Equatable, Sendable {
    var devices: [AudioDeviceControlSnapshot]
    var processes: [AudioProcessControlSnapshot]
    var processControlsAreVisible: Bool = false
    var processRuntimeError: AudioControlUserError?

    static let empty = AudioControlSnapshot(devices: [], processes: [])
}

@MainActor
protocol AudioControlCoordinating: AnyObject {
    var supportsProcessControls: Bool { get }
    var snapshot: AudioControlSnapshot { get }
    var snapshotPublisher: AnyPublisher<AudioControlSnapshot, Never> { get }

    func start() async
    func retryDevice(_ deviceUID: String)
    func setDeviceVolume(_ volume: Double, for deviceUID: String)
    func setDeviceMuted(_ isMuted: Bool, for deviceUID: String)
    func setProcessVolume(_ volume: Double, for processObjectID: AudioObjectID)
    func setProcessMuted(_ isMuted: Bool, for processObjectID: AudioObjectID)
    func setProcessRoute(_ route: AudioRouteMode, for processObjectID: AudioObjectID)
    func retry(processObjectID: AudioObjectID)
    func reset(processObjectID: AudioObjectID)
    func shutdown() async
}

typealias AudioControlDelay = @Sendable (Duration) async -> Void

@MainActor
final class AudioControlCoordinator: AudioControlCoordinating, ObservableObject {
    private enum DeviceControlIntent {
        case effectiveState(AudioEffectiveVolumeState, debounceVolume: Bool)
        case muteOnly(Bool)
    }

    private enum DeviceControlReadback {
        case volume(Double)
        case mute(Bool)
    }

    @Published private(set) var snapshot: AudioControlSnapshot = .empty

    let supportsProcessControls: Bool
    var snapshotPublisher: AnyPublisher<AudioControlSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }

    private let deviceProvider: any AudioDeviceControlProviding
    private let processProvider: any AudioProcessProviding
    private let routeDeviceProvider: any AudioRouteDeviceProviding
    private let monitor: any AudioSystemMonitoring
    private let planner: AudioRoutePlanner
    private let engine: any ProcessTapVolumeControlling
    private let preferences: PreferencesController
    private let delay: AudioControlDelay

    private var routeDevices: [AudioRouteDevice] = []
    private var confirmedDevices: [String: AudioOutputDeviceSnapshot] = [:]
    private var confirmedProcessValues: [AudioObjectID: AudioProcessControlValues] = [:]
    private var generations: [AudioObjectID: UInt64] = [:]
    private var gainIntentOrdinals: [AudioObjectID: UInt64] = [:]
    private var gainTasks: [AudioObjectID: Task<Void, Never>] = [:]
    private var retiringProcessObjectIDs: Set<AudioObjectID> = []
    private var deviceControlOrdinals: [String: UInt64] = [:]
    private var deviceControlLifetimes: [String: UInt64] = [:]
    private var deviceControlTasks: [String: Task<Void, Never>] = [:]
    private var processTasks: [AudioObjectID: Task<Void, Never>] = [:]
    private var trackedTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTrackedTaskID: UInt64 = 0
    private var monitorTask: Task<Void, Never>?
    private var engineSnapshotTask: Task<Void, Never>?
    private var latestSnapshotOrders: [AudioObjectID: ProcessTapSnapshotOrder] = [:]
    #if DEBUG
    private var reconciliationOrdinal: UInt64 = 0
    private var reconciliationWaiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
    private var processedEngineSnapshotOrders: [AudioObjectID: [ProcessTapSnapshotOrder]] = [:]
    private var engineSnapshotWaiters: [(
        AudioObjectID,
        ProcessTapSnapshotOrder,
        CheckedContinuation<Void, Never>
    )] = []
    #endif
    private var hasStarted = false
    private var shutdownWasRequested = false
    private var didBeginShutdown = false
    private var didFinishShutdown = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var processRuntimeWasStarted = false
    private var processRuntimePreparationWasAttempted = false

    static func planningUserError(
        _ error: AudioRoutePlanningError
    ) -> AudioControlUserError {
        .routePlanning(error)
    }

    init(
        availability: AudioFeatureAvailability = .current,
        deviceProvider: any AudioDeviceControlProviding,
        processProvider: any AudioProcessProviding,
        routeDeviceProvider: any AudioRouteDeviceProviding,
        monitor: any AudioSystemMonitoring,
        planner: AudioRoutePlanner = .init(),
        engine: any ProcessTapVolumeControlling,
        preferences: PreferencesController,
        delay: @escaping AudioControlDelay = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        supportsProcessControls = availability.supportsProcessControls
        self.deviceProvider = deviceProvider
        self.processProvider = processProvider
        self.routeDeviceProvider = routeDeviceProvider
        self.monitor = monitor
        self.planner = planner
        self.engine = engine
        self.preferences = preferences
        self.delay = delay
    }

    deinit {
        deviceControlTasks.values.forEach { $0.cancel() }
        processTasks.values.forEach { $0.cancel() }
        trackedTasks.values.forEach { $0.cancel() }
        monitorTask?.cancel()
        engineSnapshotTask?.cancel()
    }

    func start() async {
        guard hasStarted == false, acceptsMutations else { return }
        hasStarted = true
        do {
            try monitor.start()
        } catch {
            hasStarted = false
            return
        }
        if supportsProcessControls {
            refreshRouteDescriptors()
        }
        refreshDevices()
        let processRuntimeIsReady = await prepareProcessRuntimeIfNeeded()
        guard Task.isCancelled == false, didBeginShutdown == false else {
            if didBeginShutdown == false {
                monitor.stop()
                hasStarted = false
            }
            return
        }
        if processRuntimeIsReady {
            refreshProcesses()
        }
        do {
            try monitor.updateObservedObjects(
                deviceIDs: Set(snapshot.devices.map(\.device.objectID)),
                processObjectIDs: Set(snapshot.processes.map(\.id))
            )
        } catch {
            snapshot.processes = []
            snapshot.processControlsAreVisible = false
            monitor.stop()
            hasStarted = false
            return
        }
        startConsumers()
        if processRuntimeIsReady {
            await restoreConfirmedAndPersistedRules()
        }
    }

    func retryDevice(_ deviceUID: String) {
        guard acceptsMutations,
              let device = try? deviceProvider.outputDeviceSnapshot(forUID: deviceUID) else {
            return
        }
        if let previous = confirmedDevices[deviceUID], previous.objectID != device.objectID {
            invalidateDeviceControlLifetime(deviceUID)
        }
        confirmedDevices[deviceUID] = device
        updateDevice(deviceUID) { row in
            row.device = device
            row.error = Self.deviceError(in: device)
        }
    }

    func setDeviceVolume(_ volume: Double, for deviceUID: String) {
        let requested = min(1, max(0, volume.isFinite ? volume : 1))
        guard acceptsMutations,
              let device = snapshot.devices.first(where: { $0.id == deviceUID })?.device,
              let stateSource = requested == 0 ? confirmedDevices[deviceUID] : device,
              let current = writableDeviceState(stateSource) else { return }
        submitDeviceState(
            current.settingDisplayVolume(requested),
            for: deviceUID,
            debounceVolume: requested > 0
        )
    }

    func setDeviceMuted(_ isMuted: Bool, for deviceUID: String) {
        guard acceptsMutations,
              let device = snapshot.devices.first(where: { $0.id == deviceUID })?.device else {
            return
        }
        if let current = writableDeviceState(device),
           let target = current.settingMuted(isMuted) {
            submitDeviceState(target, for: deviceUID, debounceVolume: false)
            return
        }
        guard let current = writableMuteOnlyDeviceState(device),
              current.settingMuted(isMuted) != nil else { return }
        submitDeviceControl(.muteOnly(isMuted), for: deviceUID)
    }

    func writableDeviceState(
        _ device: AudioOutputDeviceSnapshot
    ) -> AudioEffectiveVolumeState? {
        guard case .value(let volume, isWritable: true) = device.volume,
              case .value(let muted, isWritable: true) = device.mute else { return nil }
        return AudioEffectiveVolumeState(rawVolume: volume, isMuted: muted)
    }

    private func writableMuteOnlyDeviceState(
        _ device: AudioOutputDeviceSnapshot
    ) -> AudioEffectiveVolumeState? {
        guard case .value(let volume, isWritable: false) = device.volume,
              case .value(let muted, isWritable: true) = device.mute else { return nil }
        return AudioEffectiveVolumeState(rawVolume: volume, isMuted: muted)
    }

    func isCurrentDeviceIntent(_ uid: String, ordinal: UInt64) -> Bool {
        acceptsMutations && !Task.isCancelled && deviceControlOrdinals[uid] == ordinal
    }

    private func isCurrentDeviceLifetime(
        _ uid: String,
        objectID: AudioObjectID,
        lifetime: UInt64
    ) -> Bool {
        acceptsMutations
            && deviceControlLifetimes[uid, default: 0] == lifetime
            && confirmedDevices[uid]?.objectID == objectID
    }

    private func isCurrentDeviceOperation(
        _ uid: String,
        objectID: AudioObjectID,
        lifetime: UInt64,
        ordinal: UInt64
    ) -> Bool {
        isCurrentDeviceIntent(uid, ordinal: ordinal)
            && isCurrentDeviceLifetime(uid, objectID: objectID, lifetime: lifetime)
    }

    func submitDeviceState(
        _ target: AudioEffectiveVolumeState,
        for uid: String,
        debounceVolume: Bool
    ) {
        submitDeviceControl(
            .effectiveState(target, debounceVolume: debounceVolume),
            for: uid
        )
    }

    private func submitDeviceControl(_ intent: DeviceControlIntent, for uid: String) {
        guard let fallback = confirmedDevices[uid],
              deviceCanAccept(intent, snapshot: fallback) else { return }
        let objectID = fallback.objectID
        let lifetime = deviceControlLifetimes[uid, default: 0]
        let ordinal = (deviceControlOrdinals[uid] ?? 0) &+ 1
        deviceControlOrdinals[uid] = ordinal
        let previous = deviceControlTasks[uid]
        previous?.cancel()
        updateDevice(uid) { row in
            switch intent {
            case .effectiveState(let target, _):
                row.device = Self.device(row.device, state: target)
            case .muteOnly(let muted):
                row.device = Self.device(
                    row.device,
                    mute: .value(muted, isWritable: true)
                )
            }
            row.error = nil
        }

        let task = trackedTask { @MainActor [weak self] in
            await previous?.value
            guard let self,
                  isCurrentDeviceOperation(
                    uid,
                    objectID: objectID,
                    lifetime: lifetime,
                    ordinal: ordinal
                  ) else { return }
            do {
                guard let confirmed = try await executeDeviceControl(
                    intent,
                    uid: uid,
                    objectID: objectID,
                    lifetime: lifetime,
                    ordinal: ordinal
                ) else { return }
                updateDevice(uid) { row in
                    row.device = confirmed
                    row.error = Self.deviceError(in: confirmed)
                }
            } catch {
                guard isCurrentDeviceOperation(
                    uid,
                    objectID: objectID,
                    lifetime: lifetime,
                    ordinal: ordinal
                ) else { return }
                let rolledBack = confirmedDevices[uid] ?? fallback
                updateDevice(uid) { row in
                    row.device = rolledBack
                    row.error = .deviceWrite
                }
            }
        }
        deviceControlTasks[uid] = task
    }

    private func deviceCanAccept(
        _ intent: DeviceControlIntent,
        snapshot: AudioOutputDeviceSnapshot
    ) -> Bool {
        switch intent {
        case .effectiveState:
            return writableDeviceState(snapshot) != nil
        case .muteOnly(let muted):
            guard let current = writableMuteOnlyDeviceState(snapshot) else { return false }
            return current.settingMuted(muted) != nil
        }
    }

    private func executeDeviceControl(
        _ intent: DeviceControlIntent,
        uid: String,
        objectID: AudioObjectID,
        lifetime: UInt64,
        ordinal: UInt64
    ) async throws -> AudioOutputDeviceSnapshot? {
        switch intent {
        case .effectiveState(let target, let debounceVolume):
            return try await executeEffectiveDeviceControl(
                target,
                uid: uid,
                objectID: objectID,
                lifetime: lifetime,
                ordinal: ordinal,
                debounceVolume: debounceVolume
            )
        case .muteOnly(let targetMuted):
            guard let latest = confirmedDevices[uid],
                  case .value(let volume, _) = latest.volume,
                  case .value(let currentMuted, isWritable: true) = latest.mute,
                  AudioEffectiveVolumeState(
                    rawVolume: volume,
                    isMuted: currentMuted
                  ).settingMuted(targetMuted) != nil else { return nil }
            guard currentMuted != targetMuted else { return latest }
            guard isCurrentDeviceOperation(
                uid,
                objectID: objectID,
                lifetime: lifetime,
                ordinal: ordinal
            ) else { return nil }
            let muted = try deviceProvider.writeMute(targetMuted, forUID: uid)
            guard isCurrentDeviceLifetime(uid, objectID: objectID, lifetime: lifetime),
                  let refreshed = confirmedDevices[uid] else { return nil }
            let confirmed = mergeSuccessfulDeviceReadback(.mute(muted), into: refreshed)
            confirmedDevices[uid] = confirmed
            guard isCurrentDeviceIntent(uid, ordinal: ordinal) else { return nil }
            return confirmed
        }
    }

    private func executeEffectiveDeviceControl(
        _ target: AudioEffectiveVolumeState,
        uid: String,
        objectID: AudioObjectID,
        lifetime: UInt64,
        ordinal: UInt64,
        debounceVolume: Bool
    ) async throws -> AudioOutputDeviceSnapshot? {
        guard var confirmed = confirmedDevices[uid],
              var current = writableDeviceState(confirmed) else { return nil }
        if current.rawVolume != target.rawVolume {
            if debounceVolume {
                await delay(.milliseconds(75))
                guard isCurrentDeviceOperation(
                        uid,
                        objectID: objectID,
                        lifetime: lifetime,
                        ordinal: ordinal
                      ),
                      let latest = confirmedDevices[uid],
                      let latestState = writableDeviceState(latest) else { return nil }
                confirmed = latest
                current = latestState
            }
            if current.rawVolume != target.rawVolume {
                guard isCurrentDeviceOperation(
                    uid,
                    objectID: objectID,
                    lifetime: lifetime,
                    ordinal: ordinal
                ) else { return nil }
                let volume = try deviceProvider.writeVolume(target.rawVolume, forUID: uid)
                guard isCurrentDeviceLifetime(uid, objectID: objectID, lifetime: lifetime),
                      let latest = confirmedDevices[uid] else { return nil }
                confirmed = mergeSuccessfulDeviceReadback(.volume(volume), into: latest)
                confirmedDevices[uid] = confirmed
                guard let merged = writableDeviceState(confirmed) else {
                    guard isCurrentDeviceIntent(uid, ordinal: ordinal) else { return nil }
                    return confirmed
                }
                current = merged
                guard isCurrentDeviceIntent(uid, ordinal: ordinal) else { return nil }
            }
        }
        if current.isMuted != target.isMuted {
            guard isCurrentDeviceOperation(
                uid,
                objectID: objectID,
                lifetime: lifetime,
                ordinal: ordinal
            ) else { return nil }
            let muted = try deviceProvider.writeMute(target.isMuted, forUID: uid)
            guard isCurrentDeviceLifetime(uid, objectID: objectID, lifetime: lifetime),
                  let latest = confirmedDevices[uid] else { return nil }
            confirmed = mergeSuccessfulDeviceReadback(.mute(muted), into: latest)
            confirmedDevices[uid] = confirmed
            guard isCurrentDeviceIntent(uid, ordinal: ordinal) else { return nil }
        }
        return confirmed
    }

    private func mergeSuccessfulDeviceReadback(
        _ readback: DeviceControlReadback,
        into latest: AudioOutputDeviceSnapshot
    ) -> AudioOutputDeviceSnapshot {
        switch readback {
        case .volume(let volume):
            let isWritable: Bool
            if case .value(_, let latestWritable) = latest.volume {
                isWritable = latestWritable
            } else {
                isWritable = true
            }
            return Self.device(
                latest,
                volume: .value(volume, isWritable: isWritable)
            )
        case .mute(let muted):
            let isWritable: Bool
            if case .value(_, let latestWritable) = latest.mute {
                isWritable = latestWritable
            } else {
                isWritable = true
            }
            return Self.device(
                latest,
                mute: .value(muted, isWritable: isWritable)
            )
        }
    }

    func setProcessVolume(_ volume: Double, for processObjectID: AudioObjectID) {
        updateProcessIntent(processObjectID) { values in
            let next = AudioEffectiveVolumeState(
                rawVolume: values.volume, isMuted: values.isMuted
            ).settingDisplayVolume(volume)
            values.volume = next.rawVolume
            values.isMuted = next.isMuted
        }
    }

    func setProcessMuted(_ isMuted: Bool, for processObjectID: AudioObjectID) {
        updateProcessIntent(processObjectID) { values in
            guard let next = AudioEffectiveVolumeState(
                rawVolume: values.volume, isMuted: values.isMuted
            ).settingMuted(isMuted) else { return }
            values.volume = next.rawVolume
            values.isMuted = next.isMuted
        }
    }

    func setProcessRoute(_ route: AudioRouteMode, for processObjectID: AudioObjectID) {
        updateProcessIntent(processObjectID) { $0.route = route }
    }

    func retry(processObjectID: AudioObjectID) {
        guard acceptsMutations,
              let row = snapshot.processes.first(where: { $0.id == processObjectID }),
              let values = row.pendingValues else { return }
        applyUserIntent(values, to: processObjectID)
    }

    func reset(processObjectID: AudioObjectID) {
        guard acceptsMutations else { return }
        apply(.default, to: processObjectID)
    }

    func requestShutdown() {
        guard shutdownWasRequested == false else { return }
        shutdownWasRequested = true
        for processObjectID in Array(gainTasks.keys) {
            _ = invalidateGainIntent(processObjectID)
            guard let confirmed = confirmedProcessValues[processObjectID] else { continue }
            updateProcess(processObjectID) { row in
                row.volume = confirmed.volume
                row.isMuted = confirmed.isMuted
                row.route = confirmed.route
                row.pendingValues = nil
                row.error = nil
            }
        }
    }

    func shutdown() async {
        if didFinishShutdown { return }
        if didBeginShutdown {
            await withCheckedContinuation { shutdownWaiters.append($0) }
            return
        }
        requestShutdown()
        didBeginShutdown = true
        deviceControlTasks.values.forEach { $0.cancel() }
        processTasks.values.forEach { $0.cancel() }
        let workTasks = Array(trackedTasks.values)
        workTasks.forEach { $0.cancel() }
        monitorTask?.cancel()
        engineSnapshotTask?.cancel()
        monitor.stop()
        for task in workTasks { await task.value }
        await monitorTask?.value
        await engineSnapshotTask?.value
        if processRuntimePreparationWasAttempted {
            await engine.shutdown()
        }
        hasStarted = false
        didFinishShutdown = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    #if DEBUG
    func testingWaitUntilIdle() async {
        while trackedTasks.isEmpty == false {
            let tasks = Array(trackedTasks.values)
            for task in tasks { await task.value }
        }
    }

    func testingWaitForDeviceControl(_ deviceUID: String) async {
        await deviceControlTasks[deviceUID]?.value
    }

    func testingWaitForProcessTask(_ processObjectID: AudioObjectID) async {
        await processTasks[processObjectID]?.value
    }

    func testingWaitForReconciliation(token: UInt64) async {
        guard reconciliationOrdinal < token else { return }
        await withCheckedContinuation { reconciliationWaiters.append((token, $0)) }
    }

    func testingWaitForEngineSnapshot(
        processObjectID: AudioObjectID,
        order: ProcessTapSnapshotOrder
    ) async {
        guard processedEngineSnapshotOrders[processObjectID]?.contains(order) != true else {
            return
        }
        await withCheckedContinuation {
            engineSnapshotWaiters.append((processObjectID, order, $0))
        }
    }
    #endif
}

private extension AudioControlCoordinator {
    var acceptsMutations: Bool {
        shutdownWasRequested == false && didBeginShutdown == false
    }

    func refreshRouteDescriptors() {
        routeDevices = (try? routeDeviceProvider.routeDevices()) ?? []
    }

    func refreshDevices() {
        guard let devices = try? deviceProvider.outputDeviceSnapshots() else {
            invalidateAllDeviceControlLifetimes()
            confirmedDevices.removeAll()
            snapshot.devices = []
            return
        }
        var refreshedDevices: [String: AudioOutputDeviceSnapshot] = [:]
        let refreshedRows = devices.map { device in
            refreshedDevices[device.id] = device
            return AudioDeviceControlSnapshot(
                device: device,
                error: Self.deviceError(in: device)
            )
        }
        for (uid, previous) in confirmedDevices
            where refreshedDevices[uid]?.objectID != previous.objectID {
            invalidateDeviceControlLifetime(uid)
        }
        snapshot.devices = refreshedRows
        confirmedDevices = refreshedDevices
    }

    func invalidateDeviceControlLifetime(_ uid: String) {
        deviceControlLifetimes[uid] = (deviceControlLifetimes[uid] ?? 0) &+ 1
        deviceControlOrdinals[uid] = (deviceControlOrdinals[uid] ?? 0) &+ 1
        deviceControlTasks[uid]?.cancel()
    }

    func invalidateAllDeviceControlLifetimes() {
        for uid in confirmedDevices.keys {
            invalidateDeviceControlLifetime(uid)
        }
    }

    func refreshProcesses(resetSessions: Bool = false) {
        let previous = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.id, $0) })
        let audible = processProvider.audibleOutputProcesses()
        let validated = validatedProcesses(audible, previous: previous)
        snapshot.processControlsAreVisible = validated.isEmpty == false
        snapshot.processes = validated.map { process in
            makeProcessSnapshot(
                process,
                preserving: previous[process.processObjectID],
                resetSession: resetSessions
            )
        }
    }

    func processRoute(
        for process: AudioProcessEntry,
        previous: AudioProcessControlSnapshot?
    ) -> AudioRouteMode {
        if let route = confirmedProcessValues[process.processObjectID]?.route {
            return route
        }
        if let previous { return previous.route }
        if let bundleIdentifier = process.bundleIdentifier,
           let profile = preferences.state.audioProcessProfiles[bundleIdentifier],
           profile.isDefault == false {
            return profile.route
        }
        return .followOriginal
    }

    func validatedProcesses(
        _ audible: [AudioProcessEntry],
        previous: [AudioObjectID: AudioProcessControlSnapshot]
    ) -> [AudioProcessEntry] {
        audible.filter { process in
            planner.permits(visibilityRequest(
                for: process,
                route: processRoute(for: process, previous: previous[process.processObjectID]),
                generation: 1
            ))
        }
    }

    func startConsumers() {
        if monitorTask == nil {
            monitorTask = Task { @MainActor [weak self, changes = monitor.changes] in
                for await changes in changes {
                    guard Task.isCancelled == false, let self else { return }
                    await handle(changes)
                    #if DEBUG
                    acknowledgeReconciliation()
                    #endif
                }
            }
        }
        if processRuntimeWasStarted, engineSnapshotTask == nil {
            engineSnapshotTask = Task { @MainActor [weak self, snapshots = engine.sessionSnapshots] in
                for await snapshot in snapshots {
                    guard Task.isCancelled == false, let self else { return }
                    _ = accept(snapshot)
                    #if DEBUG
                    acknowledgeEngineSnapshot(snapshot)
                    #endif
                }
            }
        }
    }

    func restoreConfirmedAndPersistedRules() async {
        guard supportsProcessControls else { return }
        let confirmedIDs = Set<AudioObjectID>(snapshot.processes.compactMap { row in
            guard confirmedProcessValues[row.id]?.isDefault == false else { return nil }
            return row.id
        })
        for id in confirmedIDs {
            guard let values = confirmedProcessValues[id] else { continue }
            apply(values, to: id)
            if let task = processTasks[id] { await task.value }
        }
        let persistedIDs = Set(snapshot.processes.map(\.id)).subtracting(confirmedIDs)
        await restorePersistedNonDefaultProfiles(processIDs: persistedIDs)
    }

    #if DEBUG
    func acknowledgeReconciliation() {
        reconciliationOrdinal &+= 1
        let ready = reconciliationWaiters.filter { reconciliationOrdinal >= $0.0 }
        reconciliationWaiters.removeAll { reconciliationOrdinal >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func acknowledgeEngineSnapshot(_ snapshot: ProcessTapSessionSnapshot) {
        processedEngineSnapshotOrders[snapshot.processObjectID, default: []].append(snapshot.order)
        let ready = engineSnapshotWaiters.filter {
            $0.0 == snapshot.processObjectID && $0.1 == snapshot.order
        }
        engineSnapshotWaiters.removeAll {
            $0.0 == snapshot.processObjectID && $0.1 == snapshot.order
        }
        ready.forEach { $0.2.resume() }
    }
    #endif

    func restorePersistedNonDefaultProfiles(processIDs: Set<AudioObjectID>? = nil) async {
        guard supportsProcessControls else { return }
        for row in snapshot.processes where processIDs?.contains(row.id) ?? true {
            guard let bundleIdentifier = row.process.bundleIdentifier,
                  let profile = preferences.state.audioProcessProfiles[bundleIdentifier],
                  profile.isDefault == false else { continue }
            let values = AudioProcessControlValues(
                volume: profile.volume,
                isMuted: profile.isMuted,
                route: profile.route
            )
            let routeOptions = makeRouteOptions(for: values.route, process: row.process)
            updateProcess(row.id) { row in
                row.volume = values.volume
                row.isMuted = values.isMuted
                row.route = values.route
                row.routeOptions = routeOptions
                row.pendingValues = values
            }
            apply(values, to: row.id)
            if let task = processTasks[row.id] { await task.value }
        }
    }

    static func deviceError(
        in device: AudioOutputDeviceSnapshot
    ) -> AudioControlUserError? {
        if case .failed(let error) = device.volume { return .deviceRead(error) }
        if case .failed(let error) = device.mute { return .deviceRead(error) }
        return nil
    }

    func updateDevice(
        _ uid: String,
        mutate: (inout AudioDeviceControlSnapshot) -> Void
    ) {
        guard let index = snapshot.devices.firstIndex(where: { $0.id == uid }) else { return }
        mutate(&snapshot.devices[index])
    }

    func updateProcess(
        _ id: AudioObjectID,
        mutate: (inout AudioProcessControlSnapshot) -> Void
    ) {
        guard let index = snapshot.processes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&snapshot.processes[index])
    }

    func updateProcessIntent(
        _ processObjectID: AudioObjectID,
        mutate: (inout AudioProcessControlValues) -> Void
    ) {
        guard acceptsMutations,
              retiringProcessObjectIDs.contains(processObjectID) == false,
              let row = snapshot.processes.first(where: { $0.id == processObjectID }) else { return }
        var values = row.pendingValues ?? AudioProcessControlValues(
            volume: row.volume,
            isMuted: row.isMuted,
            route: row.route
        )
        let originalValues = values
        let previousRoute = values.route
        mutate(&values)
        guard values != originalValues else { return }
        let routeOptions = values.route == previousRoute
            ? row.routeOptions
            : makeRouteOptions(for: values.route, process: row.process)
        updateProcess(processObjectID) { row in
            row.volume = values.volume
            row.isMuted = values.isMuted
            row.route = values.route
            row.routeOptions = routeOptions
            row.pendingValues = values
            row.error = nil
        }
        applyUserIntent(values, to: processObjectID)
    }

    func applyUserIntent(
        _ values: AudioProcessControlValues,
        to processObjectID: AudioObjectID
    ) {
        guard acceptsMutations,
              let row = snapshot.processes.first(where: { $0.id == processObjectID }),
              let confirmed = confirmedProcessValues[processObjectID],
              confirmed.isDefault == false,
              values.isDefault == false,
              values.route == confirmed.route,
              row.session.state == .running,
              row.session.generation == generations[processObjectID] else {
            apply(values, to: processObjectID)
            return
        }
        updateGain(
            values,
            replacing: confirmed,
            row: row,
            processObjectID: processObjectID,
            generation: row.session.generation
        )
    }

    func updateGain(
        _ values: AudioProcessControlValues,
        replacing confirmed: AudioProcessControlValues,
        row: AudioProcessControlSnapshot,
        processObjectID: AudioObjectID,
        generation: UInt64
    ) {
        let ordinal = (gainIntentOrdinals[processObjectID] ?? 0) &+ 1
        gainIntentOrdinals[processObjectID] = ordinal
        let previousGainTask = gainTasks[processObjectID]
        previousGainTask?.cancel()
        processTasks[processObjectID]?.cancel()
        let task = trackedTask { @MainActor [weak self] in
            await previousGainTask?.value
            guard let self,
                  isCurrentGainIntent(
                      processObjectID,
                      ordinal: ordinal,
                      generation: generation
                  ) else { return }
            await engine.updateGain(
                .init(volume: values.volume, isMuted: values.isMuted),
                for: processObjectID
            )
            guard isCurrentGainIntent(
                processObjectID,
                ordinal: ordinal,
                generation: generation
            ) else { return }
            if let bundleIdentifier = row.process.bundleIdentifier {
                do {
                    try preferences.setAudioProcessProfile(
                        .init(
                            bundleIdentifier: bundleIdentifier,
                            volume: values.volume,
                            isMuted: values.isMuted,
                            route: values.route
                        ),
                        for: bundleIdentifier
                    )
                } catch {
                    guard isCurrentGainIntent(
                        processObjectID,
                        ordinal: ordinal,
                        generation: generation
                    ) else { return }
                    await engine.updateGain(
                        .init(volume: confirmed.volume, isMuted: confirmed.isMuted),
                        for: processObjectID
                    )
                    guard isCurrentGainIntent(
                        processObjectID,
                        ordinal: ordinal,
                        generation: generation
                    ) else { return }
                    fail(values, processObjectID: processObjectID, error: .persistenceFailed)
                    return
                }
            }
            guard isCurrentGainIntent(
                processObjectID,
                ordinal: ordinal,
                generation: generation
            ) else { return }
            confirmedProcessValues[processObjectID] = values
            updateProcess(processObjectID) { row in
                row.volume = values.volume
                row.isMuted = values.isMuted
                row.route = values.route
                row.pendingValues = nil
                row.error = nil
            }
        }
        gainTasks[processObjectID] = task
        processTasks[processObjectID] = task
    }

    func apply(_ values: AudioProcessControlValues, to processObjectID: AudioObjectID) {
        guard acceptsMutations,
              supportsProcessControls,
              retiringProcessObjectIDs.contains(processObjectID) == false,
              let row = snapshot.processes.first(where: { $0.id == processObjectID }) else { return }
        let previousGainTask = invalidateGainIntent(processObjectID)
        let generation = (generations[processObjectID] ?? 0) &+ 1
        generations[processObjectID] = generation
        processTasks[processObjectID]?.cancel()
        if values.isDefault {
            processTasks[processObjectID] = trackedTask { @MainActor [weak self] in
                await previousGainTask?.value
                guard let self else { return }
                guard isCurrent(processObjectID, generation: generation) else { return }
                let confirmed = confirmedProcessValues[processObjectID] ?? .default
                let needsStop = confirmed.isDefault == false || row.session.state != .idle
                var stopped = row.session
                if needsStop {
                    stopped = await engine.stop(
                        processObjectID: processObjectID,
                        generation: generation
                    )
                    guard isCurrent(processObjectID, generation: generation) else { return }
                    guard acceptResult(stopped), stopped.state == .idle else {
                        fail(
                            values,
                            processObjectID: processObjectID,
                            error: Self.userError(stopped.error)
                        )
                        return
                    }
                }
                guard isCurrent(processObjectID, generation: generation) else { return }
                if let bundleIdentifier = row.process.bundleIdentifier {
                    do {
                        try preferences.setAudioProcessProfile(nil, for: bundleIdentifier)
                    } catch {
                        guard let rollbackGeneration = await rollbackEngine(
                            processObjectID: processObjectID,
                            failedGeneration: generation
                        ), isCurrent(processObjectID, generation: rollbackGeneration) else { return }
                        fail(values, processObjectID: processObjectID, error: .persistenceFailed)
                        return
                    }
                }
                guard isCurrent(processObjectID, generation: generation) else { return }
                let routeOptions = snapshot.processes
                    .first(where: { $0.id == processObjectID })
                    .map { makeRouteOptions(for: .followOriginal, process: $0.process) }
                confirmedProcessValues[processObjectID] = .default
                updateProcess(processObjectID) { row in
                    row.volume = 1
                    row.isMuted = false
                    row.route = .followOriginal
                    if let routeOptions { row.routeOptions = routeOptions }
                    row.pendingValues = nil
                    row.session = stopped
                    row.error = nil
                }
            }
            return
        }
        if case .explicit(let targets) = values.route {
            let unavailable = targets.filter { target in
                routeDevices.contains { $0.uid == target && $0.isAlive } == false
            }
            if unavailable.count == targets.count {
                processTasks[processObjectID] = trackedTask { @MainActor [weak self] in
                    await previousGainTask?.value
                    guard let self else { return }
                    guard isCurrent(processObjectID, generation: generation) else { return }
                    if row.session.state != .idle {
                        let stopped = await engine.stop(
                            processObjectID: processObjectID,
                            generation: generation
                        )
                        guard isCurrent(processObjectID, generation: generation) else { return }
                        guard acceptResult(stopped), stopped.state == .idle else {
                            fail(
                                values,
                                processObjectID: processObjectID,
                                error: Self.userError(stopped.error)
                            )
                            return
                        }
                    }
                    guard isCurrent(processObjectID, generation: generation) else { return }
                    let isConfirmed = confirmedProcessValues[processObjectID] == values
                    updateProcess(processObjectID) { row in
                        if isConfirmed {
                            row.volume = values.volume
                            row.isMuted = values.isMuted
                            row.route = values.route
                            row.pendingValues = nil
                        } else {
                            row.pendingValues = values
                        }
                        row.error = .targetUnavailable(unavailable)
                    }
                }
                return
            }
        }
        processTasks[processObjectID] = trackedTask { @MainActor [weak self] in
            await previousGainTask?.value
            guard let self else { return }
            guard isCurrent(processObjectID, generation: generation) else { return }
            let plan: AudioRoutePlan
            do {
                plan = try makePlan(values, for: row.process, generation: generation)
            } catch let error as AudioRoutePlanningError {
                guard isCurrent(processObjectID, generation: generation) else { return }
                fail(values, processObjectID: processObjectID, error: Self.planningUserError(error))
                return
            } catch {
                guard isCurrent(processObjectID, generation: generation) else { return }
                fail(values, processObjectID: processObjectID, error: .operationFailed(.unsupportedFormat))
                return
            }
            let result = await engine.apply(
                plan: plan,
                gain: .init(volume: values.volume, isMuted: values.isMuted)
            )
            guard isCurrent(processObjectID, generation: generation) else { return }
            guard acceptResult(result) else { return }
            guard result.state == .running else {
                fail(values, processObjectID: processObjectID, error: Self.userError(result.error))
                return
            }
            if let bundleIdentifier = row.process.bundleIdentifier {
                do {
                    try preferences.setAudioProcessProfile(
                        values.isDefault ? nil : .init(
                            bundleIdentifier: bundleIdentifier,
                            volume: values.volume,
                            isMuted: values.isMuted,
                            route: values.route
                        ),
                        for: bundleIdentifier
                    )
                } catch {
                    guard let rollbackGeneration = await rollbackEngine(
                        processObjectID: processObjectID,
                        failedGeneration: generation
                    ), isCurrent(processObjectID, generation: rollbackGeneration) else { return }
                    fail(values, processObjectID: processObjectID, error: .persistenceFailed)
                    return
                }
            }
            guard isCurrent(processObjectID, generation: generation) else { return }
            confirmedProcessValues[processObjectID] = values
            updateProcess(processObjectID) { row in
                row.volume = values.volume
                row.isMuted = values.isMuted
                row.route = values.route
                row.pendingValues = nil
                row.session = result
                row.error = nil
            }
        }
    }

    func fail(
        _ requested: AudioProcessControlValues,
        processObjectID: AudioObjectID,
        error: AudioControlUserError
    ) {
        let confirmed = confirmedProcessValues[processObjectID] ?? .default
        let routeOptions = snapshot.processes.first(where: { $0.id == processObjectID }).map { row in
            row.route == confirmed.route
                ? row.routeOptions
                : makeRouteOptions(for: confirmed.route, process: row.process)
        }
        updateProcess(processObjectID) { row in
            row.volume = confirmed.volume
            row.isMuted = confirmed.isMuted
            row.route = confirmed.route
            if let routeOptions { row.routeOptions = routeOptions }
            row.pendingValues = requested
            row.error = error
        }
    }

    static func userError(_ error: ProcessTapEngineError?) -> AudioControlUserError {
        guard let error else { return .operationFailed(.unsupportedFormat) }
        if case .permissionDenied = error { return .permissionDenied }
        return .operationFailed(error)
    }

    static func device(
        _ device: AudioOutputDeviceSnapshot,
        state: AudioEffectiveVolumeState
    ) -> AudioOutputDeviceSnapshot {
        Self.device(
            device,
            volume: .value(state.rawVolume, isWritable: true),
            mute: .value(state.isMuted, isWritable: true)
        )
    }

    static func device(
        _ device: AudioOutputDeviceSnapshot,
        volume: AudioPropertyValue<Double>? = nil,
        mute: AudioPropertyValue<Bool>? = nil
    ) -> AudioOutputDeviceSnapshot {
        AudioOutputDeviceSnapshot(
            id: device.id,
            objectID: device.objectID,
            name: device.name,
            volume: volume ?? device.volume,
            mute: mute ?? device.mute
        )
    }

    func accept(_ engineSnapshot: ProcessTapSessionSnapshot) -> Bool {
        if let currentGeneration = generations[engineSnapshot.processObjectID],
           engineSnapshot.generation < currentGeneration {
            return false
        }
        if let latest = latestSnapshotOrders[engineSnapshot.processObjectID],
           engineSnapshot.order <= latest {
            return false
        }
        latestSnapshotOrders[engineSnapshot.processObjectID] = engineSnapshot.order
        updateProcess(engineSnapshot.processObjectID) { row in
            row.session = engineSnapshot
            if engineSnapshot.state == .failed {
                row.error = Self.userError(engineSnapshot.error)
            } else if engineSnapshot.state == .running || engineSnapshot.state == .idle {
                row.error = nil
            }
        }
        return true
    }

    func acceptResult(_ engineSnapshot: ProcessTapSessionSnapshot) -> Bool {
        if accept(engineSnapshot) { return true }
        return snapshot.processes.first(where: { $0.id == engineSnapshot.processObjectID })?.session
            == engineSnapshot
    }

    func isCurrent(_ processObjectID: AudioObjectID, generation: UInt64) -> Bool {
        acceptsMutations
            && Task.isCancelled == false
            && generations[processObjectID] == generation
    }

    func isCurrentGainIntent(
        _ processObjectID: AudioObjectID,
        ordinal: UInt64,
        generation: UInt64
    ) -> Bool {
        Task.isCancelled == false
            && acceptsMutations
            && gainIntentOrdinals[processObjectID] == ordinal
            && generations[processObjectID] == generation
            && retiringProcessObjectIDs.contains(processObjectID) == false
    }

    func invalidateGainIntent(_ processObjectID: AudioObjectID) -> Task<Void, Never>? {
        gainIntentOrdinals[processObjectID] = (gainIntentOrdinals[processObjectID] ?? 0) &+ 1
        let task = gainTasks.removeValue(forKey: processObjectID)
        task?.cancel()
        return task
    }

    func trackedTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        nextTrackedTaskID &+= 1
        let id = nextTrackedTaskID
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.trackedTasks.removeValue(forKey: id)
        }
        trackedTasks[id] = task
        return task
    }

    func rollbackEngine(
        processObjectID: AudioObjectID,
        failedGeneration: UInt64
    ) async -> UInt64? {
        guard isCurrent(processObjectID, generation: failedGeneration) else { return nil }
        let previous = confirmedProcessValues[processObjectID] ?? .default
        var rollbackGeneration = failedGeneration
        if previous.isDefault == false,
           let row = snapshot.processes.first(where: { $0.id == processObjectID }),
           let plan = try? makePlan(
               previous,
               for: row.process,
               generation: failedGeneration &+ 1
           ) {
            let rollbackGeneration = failedGeneration &+ 1
            generations[processObjectID] = rollbackGeneration
            let restored = await engine.apply(
                plan: plan,
                gain: .init(volume: previous.volume, isMuted: previous.isMuted)
            )
            guard isCurrent(processObjectID, generation: rollbackGeneration) else { return nil }
            if acceptResult(restored), restored.state == .running {
                return rollbackGeneration
            }
        }
        rollbackGeneration = (generations[processObjectID] ?? rollbackGeneration) &+ 1
        generations[processObjectID] = rollbackGeneration
        let stopped = await engine.stop(
            processObjectID: processObjectID,
            generation: rollbackGeneration
        )
        guard isCurrent(processObjectID, generation: rollbackGeneration),
              acceptResult(stopped), stopped.state == .idle else { return nil }
        return rollbackGeneration
    }

    func makePlan(
        _ values: AudioProcessControlValues,
        for process: AudioProcessEntry,
        generation: UInt64
    ) throws -> AudioRoutePlan {
        try planner.plan(routeRequest(
            for: process,
            route: values.route,
            generation: generation
        ))
    }

    func routeRequest(
        for process: AudioProcessEntry,
        route: AudioRouteMode,
        generation: UInt64
    ) -> AudioRouteRequest {
        let sourceUIDs = process.outputDeviceIDs.compactMap { objectID in
            routeDevices.first(where: { $0.objectID == objectID })?.uid
        }
        let planningMode: AudioRouteMode
        switch route {
        case .followOriginal:
            planningMode = .followOriginal
        case .explicit(let targets):
            planningMode = .explicit(targetDeviceUIDs: targets.filter { target in
                routeDevices.contains { $0.uid == target && $0.isAlive }
            })
        }
        return AudioRouteRequest(
            processObjectID: process.processObjectID,
            processIdentifier: process.processIdentifier,
            generation: generation,
            sourceDeviceUIDs: sourceUIDs,
            systemDefaultOutputDeviceUID: nil,
            mode: planningMode,
            devices: routeDevices
        )
    }

    func visibilityRequest(
        for process: AudioProcessEntry,
        route: AudioRouteMode,
        generation: UInt64
    ) -> AudioRouteRequest {
        if case .explicit(let targets) = route,
           targets.contains(where: { target in
               routeDevices.contains { $0.uid == target && $0.isAlive }
           }) == false {
            return routeRequest(
                for: process,
                route: .followOriginal,
                generation: generation
            )
        }
        return routeRequest(for: process, route: route, generation: generation)
    }

    func handle(_ changes: Set<AudioSystemChange>) async {
        if changes.contains(.serviceRestarted) {
            invalidateAllDeviceControlLifetimes()
            if processRuntimeWasStarted {
                await engine.stopAll()
            }
            processRuntimeWasStarted = false
            if supportsProcessControls {
                refreshRouteDescriptors()
            }
            refreshDevices()
            let processRuntimeIsReady = await prepareProcessRuntimeIfNeeded()
            if processRuntimeIsReady {
                refreshProcesses(resetSessions: true)
            } else {
                snapshot.processes = []
            }
            if processRuntimeIsReady {
                startConsumers()
                if supportsProcessControls {
                    await restoreConfirmedAndPersistedRules()
                }
            }
            await updateMonitorObjects()
            return
        }

        let refreshesDevices = changes.contains(.deviceList)
            || changes.contains(.defaultOutputDevice)
            || changes.contains { change in
                if case .device = change { return true }
                return false
            }
        if refreshesDevices {
            if supportsProcessControls {
                refreshRouteDescriptors()
            }
            refreshDevices()
        }
        let refreshesProcesses = supportsProcessControls && (
            refreshesDevices
                || changes.contains(.processList)
                || changes.contains { change in
                    if case .process = change { return true }
                    return false
                }
        )
        if refreshesProcesses {
            await reconcileProcesses(changes: changes)
        }
        let hasLivenessChange = changes.contains { change in
            guard case .device(_, .liveness) = change else { return false }
            return true
        }
        if changes.contains(.deviceList) || hasLivenessChange {
            await reconcileExplicitTargets()
        }
        let changedSampleRateDeviceIDs = Set(changes.compactMap { change -> AudioDeviceID? in
            guard case .device(let id, .nominalSampleRate) = change else { return nil }
            return id
        })
        for deviceID in changedSampleRateDeviceIDs {
            await rebuildSessions(using: deviceID)
        }
        await updateMonitorObjects()
    }

    func reconcileProcesses(changes: Set<AudioSystemChange>) async {
        guard await prepareProcessRuntimeIfNeeded() else { return }
        let previous = snapshot.processes
        let audible = processProvider.audibleOutputProcesses()
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let current = validatedProcesses(audible, previous: previousByID)
        snapshot.processControlsAreVisible = current.isEmpty == false
        for old in previous where current.contains(where: { $0.id == old.id }) == false {
            retiringProcessObjectIDs.insert(old.id)
            let previousGainTask = invalidateGainIntent(old.id)
            processTasks.removeValue(forKey: old.id)?.cancel()
            snapshot.processes.removeAll { $0.id == old.id }
            await previousGainTask?.value
            let generation = (generations[old.id] ?? 0) &+ 1
            generations[old.id] = generation
            let stopped = await engine.stop(
                processObjectID: old.id,
                generation: generation
            )
            _ = accept(stopped)
            processTasks.removeValue(forKey: old.id)?.cancel()
            confirmedProcessValues.removeValue(forKey: old.id)
            gainIntentOrdinals.removeValue(forKey: old.id)
            latestSnapshotOrders.removeValue(forKey: old.id)
            retiringProcessObjectIDs.remove(old.id)
        }
        let newIDs = Set(current.map(\.processObjectID)).subtracting(previousByID.keys)
        snapshot.processes = current.map {
            makeProcessSnapshot($0, preserving: previousByID[$0.processObjectID])
        }
        startConsumers()
        let reenabledTargetIDs = Set(snapshot.processes.compactMap { row -> AudioObjectID? in
            guard case .targetUnavailable = row.error else { return nil }
            return row.id
        })
        await restorePersistedNonDefaultProfiles(processIDs: newIDs.union(reenabledTargetIDs))
        let changedProcessIDs = Set(changes.compactMap { change -> AudioObjectID? in
            guard case .process(let id, _) = change else { return nil }
            return id
        })
        for id in changedProcessIDs {
            guard let values = confirmedProcessValues[id],
                  values.isDefault == false,
                  values.route == .followOriginal else { continue }
            apply(values, to: id)
            if let task = processTasks[id] { await task.value }
        }
        if changes.contains(.defaultOutputDevice) {
            for row in snapshot.processes {
                guard let values = confirmedProcessValues[row.id],
                      values.isDefault == false,
                      values.route == .followOriginal else { continue }
                apply(values, to: row.id)
                if let task = processTasks[row.id] { await task.value }
            }
        }
    }

    func makeProcessSnapshot(
        _ process: AudioProcessEntry,
        preserving previous: AudioProcessControlSnapshot? = nil,
        resetSession: Bool = false
    ) -> AudioProcessControlSnapshot {
        let values = confirmedProcessValues[process.processObjectID] ?? .default
        confirmedProcessValues[process.processObjectID] = values
        let route = previous?.route ?? values.route
        return AudioProcessControlSnapshot(
            process: process,
            volume: previous?.volume ?? values.volume,
            isMuted: previous?.isMuted ?? values.isMuted,
            route: previous?.route ?? values.route,
            pendingValues: previous?.pendingValues,
            routeOptions: makeRouteOptions(for: route, process: process),
            session: resetSession ? Self.idleSession(for: process.processObjectID) :
                (previous?.session ?? Self.idleSession(for: process.processObjectID)),
            error: previous?.error
        )
    }

    func updateMonitorObjects() async {
        do {
            try monitor.updateObservedObjects(
                deviceIDs: Set(snapshot.devices.map(\.device.objectID)),
                processObjectIDs: Set(snapshot.processes.map(\.id))
            )
        } catch {
            processTasks.values.forEach { $0.cancel() }
            snapshot.processes = []
            snapshot.processControlsAreVisible = false
            monitor.stop()
            if processRuntimeWasStarted {
                await engine.stopAll()
                processRuntimeWasStarted = false
            }
            hasStarted = false
        }
    }

    func prepareProcessRuntimeIfNeeded() async -> Bool {
        guard supportsProcessControls else {
            snapshot.processRuntimeError = nil
            return false
        }
        guard processRuntimeWasStarted == false else { return true }
        processRuntimePreparationWasAttempted = true
        let preparation = await engine.prepareRuntime()
        guard Task.isCancelled == false, didBeginShutdown == false else {
            return false
        }
        switch preparation {
        case .ready:
            snapshot.processRuntimeError = nil
            processRuntimeWasStarted = true
            return true
        case .unavailable(let error):
            snapshot.processes = []
            snapshot.processControlsAreVisible = false
            snapshot.processRuntimeError = .operationFailed(error)
            return false
        }
    }

    func makeRouteOptions(
        for route: AudioRouteMode,
        process: AudioProcessEntry
    ) -> [AudioRouteDeviceOption] {
        let selectedUIDs: [String]
        switch route {
        case .followOriginal:
            selectedUIDs = process.outputDeviceIDs.compactMap { id in
                routeDevices.first(where: { $0.objectID == id })?.uid
            }
        case .explicit(let targetDeviceUIDs):
            selectedUIDs = targetDeviceUIDs
        }
        let available = routeDevices.compactMap { device -> AudioRouteDeviceOption? in
            let isSelected = selectedUIDs.contains(device.uid)
            let isEnabled = (device.isAlive || isSelected) && routeChoiceIsEnabled(
                    device.uid,
                    isSelected: isSelected,
                    route: route,
                    process: process
                )
            guard isSelected || isEnabled else { return nil }
            return AudioRouteDeviceOption(
                uid: device.uid,
                name: device.name,
                isAvailable: device.isAlive,
                isSelected: isSelected,
                isEnabled: isEnabled
            )
        }
        let knownUIDs = Set(routeDevices.map(\.uid))
        return available + selectedUIDs.filter { knownUIDs.contains($0) == false }.map {
            AudioRouteDeviceOption(
                uid: $0,
                name: $0,
                isAvailable: false,
                isSelected: true,
                isEnabled: routeChoiceIsEnabled(
                    $0,
                    isSelected: true,
                    route: route,
                    process: process
                )
            )
        }
    }

    func routeChoiceIsEnabled(
        _ uid: String,
        isSelected: Bool,
        route: AudioRouteMode,
        process: AudioProcessEntry
    ) -> Bool {
        let candidateTargets: [String]
        switch route {
        case .followOriginal:
            candidateTargets = [uid]
        case .explicit(let targetDeviceUIDs):
            candidateTargets = isSelected
                ? targetDeviceUIDs.filter { $0 != uid }
                : targetDeviceUIDs + [uid]
        }
        guard candidateTargets.isEmpty == false else { return false }
        return planner.permits(routeRequest(
            for: process,
            route: .explicit(targetDeviceUIDs: candidateTargets),
            generation: 1
        ))
    }

    static func idleSession(for processObjectID: AudioObjectID) -> ProcessTapSessionSnapshot {
        ProcessTapSessionSnapshot(
            processObjectID: processObjectID,
            generation: 0,
            state: .idle,
            error: nil
        )
    }

    func reconcileExplicitTargets() async {
        for row in snapshot.processes {
            guard let values = confirmedProcessValues[row.id],
                  values.isDefault == false,
                  case .explicit(let targets) = values.route else { continue }
            let missing = targets.filter { target in
                routeDevices.contains { $0.uid == target && $0.isAlive } == false
            }
            if missing.isEmpty {
                if case .targetUnavailable = row.error {
                    apply(values, to: row.id)
                    if let task = processTasks[row.id] { await task.value }
                }
                continue
            }
            if missing.count == targets.count {
                let previousGainTask = invalidateGainIntent(row.id)
                processTasks[row.id]?.cancel()
                await previousGainTask?.value
                let generation = (generations[row.id] ?? 0) &+ 1
                generations[row.id] = generation
                let stopped = await engine.stop(
                    processObjectID: row.id,
                    generation: generation
                )
                guard isCurrent(row.id, generation: generation) else { continue }
                guard acceptResult(stopped), stopped.state == .idle else {
                    fail(
                        values,
                        processObjectID: row.id,
                        error: Self.userError(stopped.error)
                    )
                    continue
                }
                updateProcess(row.id) { row in
                    row.volume = values.volume
                    row.isMuted = values.isMuted
                    row.route = values.route
                    row.error = .targetUnavailable(missing)
                }
            } else {
                apply(values, to: row.id)
                if let task = processTasks[row.id] { await task.value }
                updateProcess(row.id) { row in
                    row.error = .targetUnavailable(missing)
                }
            }
        }
    }

    func rebuildSessions(using deviceID: AudioDeviceID) async {
        let deviceUID = routeDevices.first(where: { $0.objectID == deviceID })?.uid
        for row in snapshot.processes {
            guard let values = confirmedProcessValues[row.id], values.isDefault == false else {
                continue
            }
            let usesDevice: Bool
            switch values.route {
            case .followOriginal:
                usesDevice = row.process.outputDeviceIDs.contains(deviceID)
            case .explicit(let targets):
                usesDevice = deviceUID.map(targets.contains) ?? false
            }
            guard usesDevice else { continue }
            apply(values, to: row.id)
            if let task = processTasks[row.id] { await task.value }
        }
    }
}
