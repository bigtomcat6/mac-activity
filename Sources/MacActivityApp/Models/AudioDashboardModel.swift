import Combine
import Foundation
import MacActivityCore

@MainActor
final class AudioDashboardModel: ObservableObject {
    @Published private(set) var devices: [AudioOutputDeviceVolume] = []
    @Published private(set) var processes: [AudioProcessEntry] = []

    private let availability: AudioFeatureAvailability
    private let deviceProvider: any AudioDeviceVolumeProviding
    private let processProvider: any AudioProcessProviding
    private let processEngine: ProcessTapVolumeEngine

    init(
        availability: AudioFeatureAvailability = .current,
        deviceProvider: any AudioDeviceVolumeProviding = AudioDeviceVolumeService(),
        processProvider: any AudioProcessProviding = AudioProcessService(),
        processEngine: ProcessTapVolumeEngine = ProcessTapVolumeEngine()
    ) {
        self.availability = availability
        self.deviceProvider = deviceProvider
        self.processProvider = processProvider
        self.processEngine = processEngine
    }

    var showsProcessControls: Bool {
        availability.supportsProcessVolume
    }

    func refresh() {
        devices = deviceProvider.outputDevices()
        processes = availability.supportsProcessVolume ? processProvider.audibleOutputProcesses() : []
    }

    func setDeviceVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) {
        guard deviceProvider.setVolume(volume, for: id) else { return }
        refresh()
    }

    func setDeviceMuted(_ isMuted: Bool, for id: AudioOutputDeviceVolume.ID) {
        guard deviceProvider.setMuted(isMuted, for: id) else { return }
        refresh()
    }

    func setProcessVolume(_ volume: Double, for processIdentifier: pid_t) {
        processEngine.setVolume(volume, processIdentifier: processIdentifier)
    }

    func setProcessMuted(_ isMuted: Bool, for processIdentifier: pid_t) {
        processEngine.setMuted(isMuted, processIdentifier: processIdentifier)
    }
}
