import Combine
import CoreAudio
import MacActivityCore

enum AudioControlUserError: Equatable, Sendable {
    case deviceRead(AudioHALError)
    case deviceWrite
    case permissionDenied
    case targetUnavailable([String])
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
    private var deviceTasks: [String: Task<Void, Never>] = [:]
    private var processTasks: [AudioObjectID: Task<Void, Never>] = [:]
    private var monitorTask: Task<Void, Never>?
    private var engineSnapshotTask: Task<Void, Never>?
    private var latestSnapshotOrders: [AudioObjectID: ProcessTapSnapshotOrder] = [:]
    private var hasStarted = false

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

    func start() async {
        guard hasStarted == false else { return }
        hasStarted = true
        _ = await engine.cleanupOrphans()
        try? monitor.start()
        startConsumers()
        refreshDevicesAndRouteDescriptors()
        if supportsProcessControls {
            refreshProcesses()
        }
        try? monitor.updateObservedObjects(
            deviceIDs: Set(snapshot.devices.map(\.device.objectID)),
            processObjectIDs: Set(snapshot.processes.map(\.id))
        )
        await restorePersistedNonDefaultProfiles()
    }

    func retryDevice(_ deviceUID: String) {
        guard let device = try? deviceProvider.outputDeviceSnapshot(forUID: deviceUID) else {
            return
        }
        confirmedDevices[deviceUID] = device
        updateDevice(deviceUID) { row in
            row.device = device
            row.error = Self.deviceError(in: device)
        }
    }

    func setDeviceVolume(_ volume: Double, for deviceUID: String) {
        guard let confirmed = confirmedDevices[deviceUID] else { return }
        let requested = min(1, max(0, volume.isFinite ? volume : 1))
        updateDevice(deviceUID) { row in
            row.device = Self.device(row.device, volume: .value(requested, isWritable: true))
            row.error = nil
        }
        deviceTasks[deviceUID]?.cancel()
        deviceTasks[deviceUID] = Task { @MainActor [weak self] in
            guard let self else { return }
            guard Task.isCancelled == false else { return }
            await delay(.milliseconds(75))
            guard Task.isCancelled == false else { return }
            do {
                let value = try deviceProvider.writeVolume(requested, forUID: deviceUID)
                let updated = Self.device(confirmed, volume: .value(value, isWritable: true))
                confirmedDevices[deviceUID] = updated
                updateDevice(deviceUID) { row in
                    row.device = updated
                    row.error = nil
                }
            } catch {
                updateDevice(deviceUID) { row in
                    row.device = confirmed
                    row.error = .deviceWrite
                }
            }
        }
    }

    func setDeviceMuted(_ isMuted: Bool, for deviceUID: String) {
        guard let confirmed = confirmedDevices[deviceUID] else { return }
        updateDevice(deviceUID) { row in
            row.device = Self.device(row.device, mute: .value(isMuted, isWritable: true))
            row.error = nil
        }
        deviceTasks[deviceUID]?.cancel()
        deviceTasks[deviceUID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try deviceProvider.writeMute(isMuted, forUID: deviceUID)
                let updated = Self.device(confirmed, mute: .value(value, isWritable: true))
                confirmedDevices[deviceUID] = updated
                updateDevice(deviceUID) { row in
                    row.device = updated
                    row.error = nil
                }
            } catch {
                updateDevice(deviceUID) { row in
                    row.device = confirmed
                    row.error = .deviceWrite
                }
            }
        }
    }

    func setProcessVolume(_ volume: Double, for processObjectID: AudioObjectID) {
        updateProcessIntent(processObjectID) { $0.volume = min(1, max(0, volume)) }
    }

    func setProcessMuted(_ isMuted: Bool, for processObjectID: AudioObjectID) {
        updateProcessIntent(processObjectID) { $0.isMuted = isMuted }
    }

    func setProcessRoute(_ route: AudioRouteMode, for processObjectID: AudioObjectID) {
        updateProcessIntent(processObjectID) { $0.route = route }
    }

    func retry(processObjectID: AudioObjectID) {
        guard let row = snapshot.processes.first(where: { $0.id == processObjectID }),
              let values = row.pendingValues else { return }
        apply(values, to: processObjectID)
    }

    func reset(processObjectID: AudioObjectID) {
        apply(.default, to: processObjectID)
    }

    func shutdown() async {
        deviceTasks.values.forEach { $0.cancel() }
        processTasks.values.forEach { $0.cancel() }
        monitorTask?.cancel()
        engineSnapshotTask?.cancel()
        monitor.stop()
        await engine.stopAll()
    }

    func testingWaitUntilIdle() async {
        while deviceTasks.isEmpty == false || processTasks.isEmpty == false {
            let tasks = Array(deviceTasks.values) + Array(processTasks.values)
            for task in tasks { await task.value }
            deviceTasks.removeAll()
            processTasks.removeAll()
        }
        for _ in 0..<12 { await Task.yield() }
    }
}

private extension AudioControlCoordinator {
    func refreshDevicesAndRouteDescriptors() {
        routeDevices = (try? routeDeviceProvider.routeDevices()) ?? []
        snapshot.devices = (try? deviceProvider.outputDeviceSnapshots().map {
            confirmedDevices[$0.id] = $0
            return AudioDeviceControlSnapshot(device: $0, error: Self.deviceError(in: $0))
        }) ?? []
    }

    func refreshProcesses() {
        snapshot.processes = processProvider.audibleOutputProcesses().map { process in
            let values = confirmedProcessValues[process.processObjectID] ?? .default
            confirmedProcessValues[process.processObjectID] = values
            return AudioProcessControlSnapshot(
                process: process,
                volume: values.volume,
                isMuted: values.isMuted,
                route: values.route,
                pendingValues: nil,
                routeOptions: routeDevices.map {
                    AudioRouteDeviceOption(
                        uid: $0.uid,
                        name: $0.name,
                        isAvailable: $0.isAlive,
                        isSelected: process.outputDeviceIDs.contains($0.objectID)
                    )
                },
                session: ProcessTapSessionSnapshot(
                    processObjectID: process.processObjectID,
                    generation: 0,
                    state: .idle,
                    error: nil
                ),
                error: nil
            )
        }
    }

    func startConsumers() {
        monitorTask = Task { @MainActor [weak self, changes = monitor.changes] in
            for await changes in changes {
                guard Task.isCancelled == false, let self else { return }
                await handle(changes)
            }
        }
        engineSnapshotTask = Task { @MainActor [weak self, snapshots = engine.sessionSnapshots] in
            for await snapshot in snapshots {
                guard Task.isCancelled == false, let self else { return }
                _ = accept(snapshot)
            }
        }
    }

    func restorePersistedNonDefaultProfiles() async {
        guard supportsProcessControls else { return }
        for row in snapshot.processes {
            guard let bundleIdentifier = row.process.bundleIdentifier,
                  let profile = preferences.state.audioProcessProfiles[bundleIdentifier],
                  profile.isDefault == false else { continue }
            let values = AudioProcessControlValues(
                volume: profile.volume,
                isMuted: profile.isMuted,
                route: profile.route
            )
            confirmedProcessValues[row.id] = values
            updateProcess(row.id) { row in
                row.volume = values.volume
                row.isMuted = values.isMuted
                row.route = values.route
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
        guard let row = snapshot.processes.first(where: { $0.id == processObjectID }) else { return }
        var values = row.pendingValues ?? AudioProcessControlValues(
            volume: row.volume,
            isMuted: row.isMuted,
            route: row.route
        )
        mutate(&values)
        updateProcess(processObjectID) { row in
            row.volume = values.volume
            row.isMuted = values.isMuted
            row.route = values.route
            row.pendingValues = values
            row.error = nil
        }
        apply(values, to: processObjectID)
    }

    func apply(_ values: AudioProcessControlValues, to processObjectID: AudioObjectID) {
        guard supportsProcessControls,
              let row = snapshot.processes.first(where: { $0.id == processObjectID }) else { return }
        let generation = (generations[processObjectID] ?? 0) &+ 1
        generations[processObjectID] = generation
        processTasks[processObjectID]?.cancel()
        if values.isDefault {
            processTasks[processObjectID] = Task { @MainActor [weak self] in
                guard let self else { return }
                if let bundleIdentifier = row.process.bundleIdentifier {
                    do {
                        try preferences.setAudioProcessProfile(nil, for: bundleIdentifier)
                    } catch {
                        fail(values, processObjectID: processObjectID, error: .persistenceFailed)
                        return
                    }
                }
                let confirmed = confirmedProcessValues[processObjectID] ?? .default
                let needsStop = confirmed.isDefault == false || row.session.state != .idle
                var stopped = row.session
                if needsStop {
                    stopped = await engine.stop(
                        processObjectID: processObjectID,
                        generation: generation
                    )
                    guard accept(stopped) || latestSnapshotOrders[processObjectID] == stopped.order else {
                        return
                    }
                }
                confirmedProcessValues[processObjectID] = .default
                updateProcess(processObjectID) { row in
                    row.volume = 1
                    row.isMuted = false
                    row.route = .followOriginal
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
                processTasks[processObjectID] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if row.session.state != .idle {
                        let stopped = await engine.stop(
                            processObjectID: processObjectID,
                            generation: generation
                        )
                        _ = accept(stopped)
                    }
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
        processTasks[processObjectID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let plan: AudioRoutePlan
            do {
                plan = try makePlan(values, for: row.process, generation: generation)
            } catch {
                fail(values, processObjectID: processObjectID, error: .operationFailed(.unsupportedFormat))
                return
            }
            let result = await engine.apply(
                plan: plan,
                gain: .init(volume: values.volume, isMuted: values.isMuted)
            )
            guard generations[processObjectID] == generation else { return }
            guard accept(result) || latestSnapshotOrders[processObjectID] == result.order else {
                return
            }
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
                    await rollbackEngine(
                        processObjectID: processObjectID,
                        failedGeneration: generation
                    )
                    fail(values, processObjectID: processObjectID, error: .persistenceFailed)
                    return
                }
            }
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
        updateProcess(processObjectID) { row in
            row.volume = confirmed.volume
            row.isMuted = confirmed.isMuted
            row.route = confirmed.route
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

    func rollbackEngine(
        processObjectID: AudioObjectID,
        failedGeneration: UInt64
    ) async {
        let previous = confirmedProcessValues[processObjectID] ?? .default
        if previous.isDefault {
            let rollbackGeneration = failedGeneration &+ 1
            generations[processObjectID] = rollbackGeneration
            let stopped = await engine.stop(
                processObjectID: processObjectID,
                generation: rollbackGeneration
            )
            _ = accept(stopped)
        } else {
            guard let row = snapshot.processes.first(where: { $0.id == processObjectID }) else {
                return
            }
            let rollbackGeneration = failedGeneration &+ 1
            generations[processObjectID] = rollbackGeneration
            guard let plan = try? makePlan(
                previous,
                for: row.process,
                generation: rollbackGeneration
            ) else { return }
            let restored = await engine.apply(
                plan: plan,
                gain: .init(volume: previous.volume, isMuted: previous.isMuted)
            )
            _ = accept(restored)
        }
    }

    func makePlan(
        _ values: AudioProcessControlValues,
        for process: AudioProcessEntry,
        generation: UInt64
    ) throws -> AudioRoutePlan {
        let sourceUIDs = process.outputDeviceIDs.compactMap { objectID in
            routeDevices.first(where: { $0.objectID == objectID })?.uid
        }
        let planningMode: AudioRouteMode
        switch values.route {
        case .followOriginal:
            planningMode = .followOriginal
        case .explicit(let targets):
            planningMode = .explicit(targetDeviceUIDs: targets.filter { target in
                routeDevices.contains { $0.uid == target && $0.isAlive }
            })
        }
        return try planner.plan(.init(
            processObjectID: process.processObjectID,
            generation: generation,
            sourceDeviceUIDs: sourceUIDs,
            systemDefaultOutputDeviceUID: nil,
            mode: planningMode,
            devices: routeDevices
        ))
    }

    func handle(_ changes: Set<AudioSystemChange>) async {
        if changes.contains(.serviceRestarted) {
            await engine.stopAll()
            refreshDevicesAndRouteDescriptors()
            refreshProcesses()
            _ = await engine.cleanupOrphans()
            await restorePersistedNonDefaultProfiles()
            updateMonitorObjects()
            return
        }

        let refreshesProcesses = changes.contains(.processList)
            || changes.contains(.defaultOutputDevice)
            || changes.contains { change in
            if case .process = change { return true }
            return false
        }
        if refreshesProcesses {
            let previous = snapshot.processes
            let current = processProvider.audibleOutputProcesses()
            for old in previous where current.contains(where: { $0.id == old.id }) == false {
                let replacementHasSamePID = current.contains {
                    $0.processIdentifier == old.process.processIdentifier && $0.id != old.id
                }
                if replacementHasSamePID || old.session.state != .idle {
                    let generation = (generations[old.id] ?? 0) &+ 1
                    generations[old.id] = generation
                    let stopped = await engine.stop(
                        processObjectID: old.id,
                        generation: generation
                    )
                    _ = accept(stopped)
                }
                confirmedProcessValues.removeValue(forKey: old.id)
                latestSnapshotOrders.removeValue(forKey: old.id)
            }
            snapshot.processes = current.map(makeProcessSnapshot)
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

        let refreshesDevices = changes.contains(.deviceList)
            || changes.contains(.defaultOutputDevice)
            || changes.contains { change in
                if case .device = change { return true }
                return false
            }
        if refreshesDevices {
            refreshDevicesAndRouteDescriptors()
            refreshRouteOptions()
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
        updateMonitorObjects()
    }

    func makeProcessSnapshot(_ process: AudioProcessEntry) -> AudioProcessControlSnapshot {
        let values = confirmedProcessValues[process.processObjectID] ?? .default
        confirmedProcessValues[process.processObjectID] = values
        return AudioProcessControlSnapshot(
            process: process,
            volume: values.volume,
            isMuted: values.isMuted,
            route: values.route,
            pendingValues: nil,
            routeOptions: routeDevices.map {
                AudioRouteDeviceOption(
                    uid: $0.uid,
                    name: $0.name,
                    isAvailable: $0.isAlive,
                    isSelected: process.outputDeviceIDs.contains($0.objectID)
                )
            },
            session: ProcessTapSessionSnapshot(
                processObjectID: process.processObjectID,
                generation: 0,
                state: .idle,
                error: nil
            ),
            error: nil
        )
    }

    func updateMonitorObjects() {
        try? monitor.updateObservedObjects(
            deviceIDs: Set(snapshot.devices.map(\.device.objectID)),
            processObjectIDs: Set(snapshot.processes.map(\.id))
        )
    }

    func refreshRouteOptions() {
        for index in snapshot.processes.indices {
            let selected: [String]
            switch snapshot.processes[index].route {
            case .followOriginal:
                selected = snapshot.processes[index].process.outputDeviceIDs.compactMap { id in
                    routeDevices.first(where: { $0.objectID == id })?.uid
                }
            case .explicit(let targetDeviceUIDs):
                selected = targetDeviceUIDs
            }
            snapshot.processes[index].routeOptions = routeDevices.map {
                AudioRouteDeviceOption(
                    uid: $0.uid,
                    name: $0.name,
                    isAvailable: $0.isAlive,
                    isSelected: selected.contains($0.uid)
                )
            }
        }
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
                let generation = (generations[row.id] ?? 0) &+ 1
                generations[row.id] = generation
                let stopped = await engine.stop(
                    processObjectID: row.id,
                    generation: generation
                )
                _ = accept(stopped)
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
