import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AudioDashboardViewTests: XCTestCase {
    func testLowVersionRendersDeviceSectionWithoutProcessSection() throws {
        let model = AudioDashboardModel(
            coordinator: TestAudioControlCoordinator(
                supportsProcessControls: false,
                snapshot: AudioControlSnapshot(
                    devices: [
                        AudioDeviceControlSnapshot(
                            device: AudioOutputDeviceSnapshot(
                                id: "BuiltInOutput",
                                objectID: 1,
                                name: "MacBook Speakers",
                                volume: .value(0.5, isWritable: true),
                                mute: .value(false, isWritable: true)
                            ),
                            error: nil
                        )
                    ],
                    processes: []
                )
            )
        )
        model.refresh()

        let view = AudioDashboardView(model: model)
            .frame(width: 360, height: 320)

        XCTAssertNotNil(Self.renderedColor(of: view, atTopLeft: CGPoint(x: 180, y: 170)))
        XCTAssertFalse(model.showsProcessControls)
    }
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
