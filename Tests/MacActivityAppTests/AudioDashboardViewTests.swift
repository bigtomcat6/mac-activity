import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioDashboardViewTests: XCTestCase {
    func testLowVersionRendersDeviceSectionWithoutProcessSection() throws {
        let model = AudioDashboardModel(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)
            ),
            deviceProvider: AudioDashboardViewDeviceProviderStub(devices: [
                AudioDeviceVolumeService.makeDevice(
                    id: "BuiltInOutput",
                    name: "MacBook Speakers",
                    volume: 0.5,
                    isMuted: false,
                    canSetVolume: true,
                    canSetMute: true
                )
            ]),
            processProvider: AudioDashboardViewProcessProviderStub(processes: [
                AudioProcessEntry(
                    processObjectID: 11,
                    processIdentifier: 101,
                    name: "Music",
                    bundleIdentifier: nil,
                    bundleURL: nil
                )
            ]),
            processEngine: AudioDashboardViewProcessEngineStub()
        )
        model.refresh()

        let view = AudioDashboardView(model: model)
            .frame(width: 360, height: 320)

        XCTAssertNotNil(Self.renderedColor(of: view, atTopLeft: CGPoint(x: 180, y: 170)))
        XCTAssertFalse(model.showsProcessControls)
    }
}

@MainActor
private final class AudioDashboardViewDeviceProviderStub: AudioDeviceVolumeProviding {
    private let devices: [AudioOutputDeviceVolume]

    init(devices: [AudioOutputDeviceVolume]) {
        self.devices = devices
    }

    func outputDevices() -> [AudioOutputDeviceVolume] {
        devices
    }

    func setVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) -> Bool {
        false
    }

    func setMuted(_ isMuted: Bool, for id: AudioOutputDeviceVolume.ID) -> Bool {
        false
    }
}

@MainActor
private final class AudioDashboardViewProcessProviderStub: AudioProcessProviding {
    private let processes: [AudioProcessEntry]

    init(processes: [AudioProcessEntry]) {
        self.processes = processes
    }

    func audibleOutputProcesses() -> [AudioProcessEntry] {
        processes
    }
}

@MainActor
private final class AudioDashboardViewProcessEngineStub: AudioProcessVolumeControlling {
    func start(entry: AudioProcessEntry) throws {}
    func stop(processIdentifier: pid_t) {}
    func setVolume(_ volume: Double, processIdentifier: pid_t) {}
    func setMuted(_ isMuted: Bool, processIdentifier: pid_t) {}
}

private extension AudioDashboardViewTests {
    static func renderedColor<Content: View>(
        of view: Content,
        atTopLeft point: CGPoint
    ) -> NSColor? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        let pixelX = Int(point.x.rounded(.down))
        let sourceY = Int(point.y.rounded(.down))
        let pixelY = bitmap.pixelsHigh - sourceY - 1

        guard (0..<bitmap.pixelsWide).contains(pixelX),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            return nil
        }

        return bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
    }
}
