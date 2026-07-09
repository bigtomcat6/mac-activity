import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioDashboardModelTests: XCTestCase {
    func testRefreshHidesProcessControlsWhenUnsupported() {
        let deviceProvider = AudioDeviceVolumeProviderStub(devices: [
            AudioDeviceVolumeService.makeDevice(
                id: "BuiltInOutput",
                name: "MacBook Speakers",
                volume: 0.5,
                isMuted: false,
                canSetVolume: true,
                canSetMute: true
            )
        ])
        let processProvider = AudioProcessProviderStub(processes: [Self.musicProcess], callCount: 0)
        let processEngine = AudioProcessVolumeControllerStub()
        let model = AudioDashboardModel(
            availability: Self.unsupportedAvailability,
            deviceProvider: deviceProvider,
            processProvider: processProvider,
            processEngine: processEngine
        )

        model.refresh()

        XCTAssertEqual(model.devices.count, 1)
        XCTAssertFalse(model.showsProcessControls)
        XCTAssertTrue(model.processes.isEmpty)
        XCTAssertEqual(processProvider.callCount, 0)
        XCTAssertEqual(processEngine.startedEntries, [])
        XCTAssertEqual(processEngine.stoppedProcessIdentifiers, [])
    }

    func testRefreshLoadsProcessControlsOnlyForProcessesWithSuccessfulTapStart() {
        let processEngine = AudioProcessVolumeControllerStub(startResults: [101: .success(())])
        let model = AudioDashboardModel(
            availability: Self.supportedAvailability,
            deviceProvider: AudioDeviceVolumeProviderStub(devices: []),
            processProvider: AudioProcessProviderStub(processes: [Self.musicProcess]),
            processEngine: processEngine
        )

        model.refresh()

        XCTAssertTrue(model.showsProcessControls)
        XCTAssertEqual(model.processes.map { $0.name }, ["Music"])
        XCTAssertEqual(processEngine.startedEntries.map { $0.processIdentifier }, [101])
    }

    func testRefreshHidesProcessControlsWhenTapStartFails() {
        let processEngine = AudioProcessVolumeControllerStub(startResults: [101: .failure(ProcessTapVolumeEngine.Error.processTapsUnavailable)])
        let model = AudioDashboardModel(
            availability: Self.supportedAvailability,
            deviceProvider: AudioDeviceVolumeProviderStub(devices: []),
            processProvider: AudioProcessProviderStub(processes: [Self.musicProcess]),
            processEngine: processEngine
        )

        model.refresh()

        XCTAssertFalse(model.showsProcessControls)
        XCTAssertTrue(model.processes.isEmpty)
        XCTAssertEqual(processEngine.startedEntries.map { $0.processIdentifier }, [101])
    }

    func testRefreshDoesNotRestartActiveTapAndStopsMissingProcess() {
        let processEngine = AudioProcessVolumeControllerStub(startResults: [101: .success(())])
        let processProvider = AudioProcessProviderStub(processSequences: [
            [Self.musicProcess],
            [Self.musicProcess],
            []
        ])
        let model = AudioDashboardModel(
            availability: Self.supportedAvailability,
            deviceProvider: AudioDeviceVolumeProviderStub(devices: []),
            processProvider: processProvider,
            processEngine: processEngine
        )

        model.refresh()
        model.refresh()
        model.refresh()

        XCTAssertEqual(processEngine.startedEntries.map { $0.processIdentifier }, [101])
        XCTAssertEqual(processEngine.stoppedProcessIdentifiers, [101])
        XCTAssertTrue(model.processes.isEmpty)
        XCTAssertFalse(model.showsProcessControls)
    }

    func testSetDeviceVolumeRefreshesAfterSuccessfulWrite() {
        let deviceProvider = AudioDeviceVolumeProviderStub(
            devices: [Self.device],
            setVolumeResult: true
        )
        let model = AudioDashboardModel(
            availability: Self.unsupportedAvailability,
            deviceProvider: deviceProvider,
            processProvider: AudioProcessProviderStub(processes: []),
            processEngine: AudioProcessVolumeControllerStub()
        )

        model.refresh()
        model.setDeviceVolume(0.75, for: Self.device.id)

        XCTAssertEqual(deviceProvider.outputDevicesCallCount, 2)
        XCTAssertEqual(model.devices.first?.volume, 0.75)
    }

    func testSetDeviceVolumeDoesNotRefreshAfterFailedWrite() {
        let deviceProvider = AudioDeviceVolumeProviderStub(
            devices: [Self.device],
            setVolumeResult: false
        )
        let model = AudioDashboardModel(
            availability: Self.unsupportedAvailability,
            deviceProvider: deviceProvider,
            processProvider: AudioProcessProviderStub(processes: []),
            processEngine: AudioProcessVolumeControllerStub()
        )

        model.refresh()
        model.setDeviceVolume(0.75, for: Self.device.id)

        XCTAssertEqual(deviceProvider.outputDevicesCallCount, 1)
        XCTAssertEqual(model.devices.first?.volume, Self.device.volume)
    }

    func testSetDeviceMutedRefreshesAfterSuccessfulWrite() {
        let deviceProvider = AudioDeviceVolumeProviderStub(
            devices: [Self.device],
            setMutedResult: true
        )
        let model = AudioDashboardModel(
            availability: Self.unsupportedAvailability,
            deviceProvider: deviceProvider,
            processProvider: AudioProcessProviderStub(processes: []),
            processEngine: AudioProcessVolumeControllerStub()
        )

        model.refresh()
        model.setDeviceMuted(true, for: Self.device.id)

        XCTAssertEqual(deviceProvider.outputDevicesCallCount, 2)
        XCTAssertEqual(model.devices.first?.isMuted, true)
    }

    func testSetDeviceMutedDoesNotRefreshAfterFailedWrite() {
        let deviceProvider = AudioDeviceVolumeProviderStub(
            devices: [Self.device],
            setMutedResult: false
        )
        let model = AudioDashboardModel(
            availability: Self.unsupportedAvailability,
            deviceProvider: deviceProvider,
            processProvider: AudioProcessProviderStub(processes: []),
            processEngine: AudioProcessVolumeControllerStub()
        )

        model.refresh()
        model.setDeviceMuted(true, for: Self.device.id)

        XCTAssertEqual(deviceProvider.outputDevicesCallCount, 1)
        XCTAssertEqual(model.devices.first?.isMuted, Self.device.isMuted)
    }

    func testProcessSettersForwardToProcessEngine() {
        let processEngine = AudioProcessVolumeControllerStub()
        let model = AudioDashboardModel(
            availability: Self.supportedAvailability,
            deviceProvider: AudioDeviceVolumeProviderStub(devices: []),
            processProvider: AudioProcessProviderStub(processes: []),
            processEngine: processEngine
        )

        model.setProcessVolume(0.35, for: 101)
        model.setProcessMuted(true, for: 101)

        XCTAssertEqual(processEngine.setVolumeCalls.count, 1)
        XCTAssertEqual(processEngine.setVolumeCalls.first?.volume, 0.35)
        XCTAssertEqual(processEngine.setVolumeCalls.first?.processIdentifier, 101)
        XCTAssertEqual(processEngine.setMutedCalls.count, 1)
        XCTAssertEqual(processEngine.setMutedCalls.first?.isMuted, true)
        XCTAssertEqual(processEngine.setMutedCalls.first?.processIdentifier, 101)
    }
}

@MainActor
private extension AudioDashboardModelTests {
    static let unsupportedAvailability = AudioFeatureAvailability(
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)
    )

    static let supportedAvailability = AudioFeatureAvailability(
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
    )

    static let device = AudioDeviceVolumeService.makeDevice(
        id: "BuiltInOutput",
        name: "MacBook Speakers",
        volume: 0.5,
        isMuted: false,
        canSetVolume: true,
        canSetMute: true
    )

    static let musicProcess = AudioProcessEntry(
        processObjectID: 11,
        processIdentifier: 101,
        name: "Music",
        bundleIdentifier: nil,
        bundleURL: nil
    )
}

@MainActor
private final class AudioDeviceVolumeProviderStub: AudioDeviceVolumeProviding {
    private(set) var devices: [AudioOutputDeviceVolume]
    private let setVolumeResult: Bool
    private let setMutedResult: Bool
    private(set) var outputDevicesCallCount = 0

    init(
        devices: [AudioOutputDeviceVolume],
        setVolumeResult: Bool = true,
        setMutedResult: Bool = true
    ) {
        self.devices = devices
        self.setVolumeResult = setVolumeResult
        self.setMutedResult = setMutedResult
    }

    func outputDevices() -> [AudioOutputDeviceVolume] {
        outputDevicesCallCount += 1
        return devices
    }

    func setVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) -> Bool {
        guard setVolumeResult, let index = devices.firstIndex(where: { $0.id == id }) else { return false }

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
        guard setMutedResult, let index = devices.firstIndex(where: { $0.id == id }) else { return false }

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
    private let processSequences: [[AudioProcessEntry]]
    private(set) var callCount: Int

    init(processes: [AudioProcessEntry], callCount: Int = 0) {
        self.processSequences = [processes]
        self.callCount = callCount
    }

    init(processSequences: [[AudioProcessEntry]], callCount: Int = 0) {
        self.processSequences = processSequences
        self.callCount = callCount
    }

    func audibleOutputProcesses() -> [AudioProcessEntry] {
        let index = min(callCount, processSequences.count - 1)
        callCount += 1
        return processSequences[index]
    }
}

@MainActor
private final class AudioProcessVolumeControllerStub: AudioProcessVolumeControlling {
    private(set) var startedEntries: [AudioProcessEntry] = []
    private(set) var stoppedProcessIdentifiers: [pid_t] = []
    private(set) var setVolumeCalls: [SetVolumeCall] = []
    private(set) var setMutedCalls: [SetMutedCall] = []
    private let startResults: [pid_t: Result<Void, Error>]

    init(startResults: [pid_t: Result<Void, Error>] = [:]) {
        self.startResults = startResults
    }

    func start(entry: AudioProcessEntry) throws {
        startedEntries.append(entry)

        switch startResults[entry.processIdentifier, default: .success(())] {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func stop(processIdentifier: pid_t) {
        stoppedProcessIdentifiers.append(processIdentifier)
    }

    func setVolume(_ volume: Double, processIdentifier: pid_t) {
        setVolumeCalls.append(SetVolumeCall(volume: volume, processIdentifier: processIdentifier))
    }

    func setMuted(_ isMuted: Bool, processIdentifier: pid_t) {
        setMutedCalls.append(SetMutedCall(isMuted: isMuted, processIdentifier: processIdentifier))
    }
}

private struct SetVolumeCall: Equatable {
    let volume: Double
    let processIdentifier: pid_t
}

private struct SetMutedCall: Equatable {
    let isMuted: Bool
    let processIdentifier: pid_t
}
