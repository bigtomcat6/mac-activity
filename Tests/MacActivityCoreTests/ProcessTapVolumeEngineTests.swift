import XCTest
@testable import MacActivityCore

final class ProcessTapVolumeEngineTests: XCTestCase {
    func testVolumeStateClampsAndMuteZeroesEffectiveVolume() {
        var state = ProcessAudioVolumeState(processIdentifier: 101, volume: 1, isMuted: false)
        state.setVolume(1.4)
        XCTAssertEqual(state.volume, 1)

        state.setVolume(-0.2)
        XCTAssertEqual(state.volume, 0)

        state.setVolume(0.7)
        state.isMuted = true
        XCTAssertEqual(state.effectiveVolume, 0)

        state.isMuted = false
        XCTAssertEqual(state.effectiveVolume, 0.7, accuracy: 0.001)
    }

    func testRealtimeGainBoxAtomicallyStoresAndLoadsFloatBitPattern() {
        let box = RealtimeProcessGainBox(initialValue: 1)
        XCTAssertEqual(box.load(), 1, accuracy: 0.001)

        box.set(0.375)
        XCTAssertEqual(box.load(), 0.375, accuracy: 0.001)

        box.set(0)
        XCTAssertEqual(box.load(), 0, accuracy: 0.001)
    }

    @MainActor
    func testEngineRefusesProcessTapWhenFeatureGateIsDisabled() {
        let engine = ProcessTapVolumeEngine(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)
            )
        )

        XCTAssertThrowsError(try engine.start(entry: AudioProcessEntry(
            processObjectID: 11,
            processIdentifier: 101,
            name: "Music",
            bundleIdentifier: "com.apple.Music",
            bundleURL: nil
        ))) { error in
            XCTAssertEqual(error as? ProcessTapVolumeEngine.Error, .processTapsUnavailable)
        }
    }
}
