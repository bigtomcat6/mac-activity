import Combine
import Foundation
import MacActivityCore

@MainActor
protocol AudioProcessVolumeControlling: AnyObject {
    func start(entry: AudioProcessEntry) throws
    func stop(processIdentifier: pid_t)
    func setVolume(_ volume: Double, processIdentifier: pid_t)
    func setMuted(_ isMuted: Bool, processIdentifier: pid_t)
}

extension ProcessTapVolumeEngine: AudioProcessVolumeControlling {}

@MainActor
final class AudioDashboardModel: ObservableObject {
    @Published private(set) var devices: [AudioOutputDeviceVolume] = []
    @Published private(set) var processes: [AudioProcessEntry] = []

    private let availability: AudioFeatureAvailability
    private let deviceProvider: any AudioDeviceVolumeProviding
    private let processProvider: any AudioProcessProviding
    private let processEngine: any AudioProcessVolumeControlling
    private var activeProcessIdentifiers: Set<pid_t> = []

    init(
        availability: AudioFeatureAvailability = .current,
        deviceProvider: any AudioDeviceVolumeProviding = AudioDeviceVolumeService(),
        processProvider: any AudioProcessProviding = AudioProcessService(),
        processEngine: any AudioProcessVolumeControlling = ProcessTapVolumeEngine()
    ) {
        self.availability = availability
        self.deviceProvider = deviceProvider
        self.processProvider = processProvider
        self.processEngine = processEngine
    }

    var showsProcessControls: Bool {
        !processes.isEmpty
    }

    func refresh() {
        devices = deviceProvider.outputDevices()

        guard availability.supportsProcessVolume else {
            stopActiveProcesses(activeProcessIdentifiers)
            activeProcessIdentifiers.removeAll()
            processes = []
            return
        }

        let candidates = processProvider.audibleOutputProcesses()
        let candidateIdentifiers = Set(candidates.map(\.processIdentifier))
        var activeEntries: [AudioProcessEntry] = []

        for entry in candidates {
            if activeProcessIdentifiers.contains(entry.processIdentifier) {
                activeEntries.append(entry)
                continue
            }

            do {
                try processEngine.start(entry: entry)
                activeProcessIdentifiers.insert(entry.processIdentifier)
                activeEntries.append(entry)
            } catch {
                continue
            }
        }

        let inactiveIdentifiers = activeProcessIdentifiers.subtracting(candidateIdentifiers)
        stopActiveProcesses(inactiveIdentifiers)
        activeProcessIdentifiers.subtract(inactiveIdentifiers)
        processes = activeEntries
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

    private func stopActiveProcesses(_ processIdentifiers: Set<pid_t>) {
        for processIdentifier in processIdentifiers {
            processEngine.stop(processIdentifier: processIdentifier)
        }
    }
}
