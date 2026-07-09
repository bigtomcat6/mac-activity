import XCTest
@testable import MacActivityCore

final class AudioDeviceVolumeServiceTests: XCTestCase {
    func testDeviceRowsExposeWritableHardwareVolume() {
        let device = AudioDeviceVolumeService.makeDevice(
            id: "BuiltInOutput",
            name: "MacBook Speakers",
            volume: 0.42,
            isMuted: false,
            canSetVolume: true,
            canSetMute: true
        )

        XCTAssertEqual(device.id, "BuiltInOutput")
        XCTAssertEqual(device.name, "MacBook Speakers")
        XCTAssertEqual(device.volume, 0.42, accuracy: 0.001)
        XCTAssertEqual(device.volumeAvailability, .writable)
        XCTAssertEqual(device.muteAvailability, .writable)
    }

    func testDeviceRowsMarkUnsupportedVolumeAsReadOnly() {
        let device = AudioDeviceVolumeService.makeDevice(
            id: "HDMI",
            name: "Display Audio",
            volume: nil,
            isMuted: nil,
            canSetVolume: false,
            canSetMute: false
        )

        XCTAssertEqual(device.volume, 1.0)
        XCTAssertEqual(device.volumeAvailability, .unsupported)
        XCTAssertEqual(device.muteAvailability, .unsupported)
    }

    func testVolumeInputIsClampedForWrites() {
        XCTAssertEqual(AudioDeviceVolumeService.clampedVolume(-0.5), 0)
        XCTAssertEqual(AudioDeviceVolumeService.clampedVolume(0.5), 0.5)
        XCTAssertEqual(AudioDeviceVolumeService.clampedVolume(1.5), 1)
    }
}
