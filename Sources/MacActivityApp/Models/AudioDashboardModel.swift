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

    #if DEBUG
    var testingCoordinator: AnyObject { coordinator }
    #endif
}
