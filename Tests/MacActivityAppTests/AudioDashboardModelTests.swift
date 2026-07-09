import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioDashboardModelTests: XCTestCase {
    func testRefreshHidesProcessControlsWhenUnsupported() {
        let model = AudioDashboardModel(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)
            ),
            deviceProvider: AudioDeviceVolumeProviderStub(devices: [
                AudioDeviceVolumeService.makeDevice(
                    id: "BuiltInOutput",
                    name: "MacBook Speakers",
                    volume: 0.5,
                    isMuted: false,
                    canSetVolume: true,
                    canSetMute: true
                )
            ]),
            processProvider: AudioProcessProviderStub(processes: [
                AudioProcessEntry(processObjectID: 11, processIdentifier: 101, name: "Music", bundleIdentifier: nil, bundleURL: nil)
            ]),
            processEngine: ProcessTapVolumeEngine(
                availability: AudioFeatureAvailability(
                    operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)
                )
            )
        )

        model.refresh()

        XCTAssertEqual(model.devices.count, 1)
        XCTAssertFalse(model.showsProcessControls)
        XCTAssertEqual(model.processes, [])
    }

    func testRefreshLoadsProcessControlsWhenSupported() {
        let availability = AudioFeatureAvailability(
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        )
        let model = AudioDashboardModel(
            availability: availability,
            deviceProvider: AudioDeviceVolumeProviderStub(devices: []),
            processProvider: AudioProcessProviderStub(processes: [
                AudioProcessEntry(processObjectID: 11, processIdentifier: 101, name: "Music", bundleIdentifier: nil, bundleURL: nil)
            ]),
            processEngine: ProcessTapVolumeEngine(availability: availability)
        )

        model.refresh()

        XCTAssertTrue(model.showsProcessControls)
        XCTAssertEqual(model.processes.map(\.name), ["Music"])
    }
}

@MainActor
private final class AudioDeviceVolumeProviderStub: AudioDeviceVolumeProviding {
    private(set) var devices: [AudioOutputDeviceVolume]

    init(devices: [AudioOutputDeviceVolume]) {
        self.devices = devices
    }

    func outputDevices() -> [AudioOutputDeviceVolume] {
        devices
    }

    func setVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }

        let device = devices[index]
        devices[index] = AudioOutputDeviceVolume(
            id: device.id,
            name: device.name,
            volume: AudioDeviceVolumeService.clampedVolume(volume),
            isMuted: device.isMuted,
            volumeAvailability: device.volumeAvailability,
            muteAvailability: device.muteAvailability
        )
        return true
    }

    func setMuted(_ isMuted: Bool, for id: AudioOutputDeviceVolume.ID) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }

        let device = devices[index]
        devices[index] = AudioOutputDeviceVolume(
            id: device.id,
            name: device.name,
            volume: device.volume,
            isMuted: isMuted,
            volumeAvailability: device.volumeAvailability,
            muteAvailability: device.muteAvailability
        )
        return true
    }
}

@MainActor
private final class AudioProcessProviderStub: AudioProcessProviding {
    private let processes: [AudioProcessEntry]

    init(processes: [AudioProcessEntry]) {
        self.processes = processes
    }

    func audibleOutputProcesses() -> [AudioProcessEntry] {
        processes
    }
}
