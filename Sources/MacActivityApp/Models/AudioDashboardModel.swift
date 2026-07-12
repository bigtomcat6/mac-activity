import Combine
import CoreAudio
import Foundation
import MacActivityCore

@MainActor
final class AudioDashboardModel: ObservableObject {
    @Published private(set) var snapshot: AudioControlSnapshot
    let supportsProcessControls: Bool

    private let coordinator: any AudioControlCoordinating
    private var snapshotCancellable: AnyCancellable?

    init(coordinator: any AudioControlCoordinating) {
        self.coordinator = coordinator
        self.snapshot = coordinator.snapshot
        self.supportsProcessControls = coordinator.supportsProcessControls
        self.snapshotCancellable = coordinator.snapshotPublisher.sink { [weak self] snapshot in
            self?.snapshot = snapshot
        }
    }

    func retryDevice(_ uid: String) { coordinator.retryDevice(uid) }

    func setDeviceVolume(_ value: Double, for uid: String) {
        coordinator.setDeviceVolume(value, for: uid)
    }

    func setDeviceMuted(_ value: Bool, for uid: String) {
        coordinator.setDeviceMuted(value, for: uid)
    }

    func setProcessVolume(_ value: Double, for id: AudioObjectID) {
        coordinator.setProcessVolume(value, for: id)
    }

    func setProcessMuted(_ value: Bool, for id: AudioObjectID) {
        coordinator.setProcessMuted(value, for: id)
    }

    func setProcessRoute(_ route: AudioRouteMode, for id: AudioObjectID) {
        coordinator.setProcessRoute(route, for: id)
    }

    func retry(processObjectID: AudioObjectID) {
        coordinator.retry(processObjectID: processObjectID)
    }

    func reset(processObjectID: AudioObjectID) {
        coordinator.reset(processObjectID: processObjectID)
    }

    // Removed in Task 11 after AudioDashboardView consumes `snapshot` directly.
    var devices: [AudioOutputDeviceVolume] {
        snapshot.devices.compactMap { row in
            guard case .value(let volume, let canSetVolume) = row.device.volume,
                  case .value(let isMuted, let canSetMute) = row.device.mute else {
                return nil
            }
            return AudioOutputDeviceVolume(
                id: row.id,
                name: row.device.name,
                volume: volume,
                isMuted: isMuted,
                volumeAvailability: canSetVolume ? .writable : .unsupported,
                muteAvailability: canSetMute ? .writable : .unsupported
            )
        }
    }

    var processes: [AudioProcessEntry] { snapshot.processes.map(\.process) }
    var showsProcessControls: Bool { supportsProcessControls && processes.isEmpty == false }
    func refresh() {}

    func setProcessVolume(_ value: Double, for processIdentifier: pid_t) {
        guard let process = snapshot.processes.first(where: {
            $0.process.processIdentifier == processIdentifier
        }) else { return }
        setProcessVolume(value, for: process.id)
    }

    func setProcessMuted(_ value: Bool, for processIdentifier: pid_t) {
        guard let process = snapshot.processes.first(where: {
            $0.process.processIdentifier == processIdentifier
        }) else { return }
        setProcessMuted(value, for: process.id)
    }

    #if DEBUG
    var testingCoordinator: AnyObject { coordinator }
    #endif
}
