import AppKit
import XCTest
@testable import DebugGlassPrototype

@MainActor
final class PrototypePanelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testPanelUsesPublicTransparentNonactivatingConfiguration() {
        let panel = PrototypePanelFactory.makePanel(
            contentRect: NSRect(x: 100, y: 200, width: 420, height: 480)
        )
        defer { panel.close() }

        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, NSColor.clear)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.level, .popUpMenu)
        XCTAssertEqual(panel.identifier?.rawValue, PrototypePanelFactory.identifier)
    }

    @available(macOS 26.0, *)
    func testPrototypeOwnedWindowsOptOutOfReleaseOnClose() {
        let anchor = PrototypeAnchorWindow(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertFalse(anchor.isReleasedWhenClosed)
        if anchor.isReleasedWhenClosed == false {
            anchor.close()
            XCTAssertEqual(anchor.identifier?.rawValue, PrototypeAnchorWindow.anchorIdentifier)
        }

        let panel = PrototypePanelFactory.makePanel(
            contentRect: NSRect(x: 100, y: 200, width: 420, height: 480)
        )
        XCTAssertFalse(panel.isReleasedWhenClosed)
        panel.close()
    }

    @available(macOS 26.0, *)
    func testBackdropWindowOptsOutOfReleaseOnClose() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw XCTSkip("no screens available in this session")
        }
        let backdrop = PrototypeBackdropWindow(screen: screen)
        XCTAssertFalse(backdrop.isReleasedWhenClosed)
        if backdrop.isReleasedWhenClosed == false {
            backdrop.close()
            XCTAssertEqual(backdrop.identifier?.rawValue, PrototypeBackdropWindow.backdropIdentifier)
        }
    }

    func testAnchorResolverConvertsViewBoundsIntoScreenCoordinates() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        Self.retainedWindows.append(window)
        let view = NSView(frame: NSRect(x: 20, y: 30, width: 40, height: 20))
        window.contentView = view

        let expected = window.convertToScreen(view.convert(view.bounds, to: nil))

        XCTAssertEqual(PrototypeAnchorResolver.screenRect(for: view), expected)
        XCTAssertNil(PrototypeAnchorResolver.screenRect(for: nil))
    }

    private static var retainedWindows: [NSWindow] = []
}
