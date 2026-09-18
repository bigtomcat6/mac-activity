import XCTest
@testable import DebugGlassPrototype

final class PrototypePaletteTests: XCTestCase {
    func testClearForegroundLayersAreOrderedWhiteLevels() {
        XCTAssertGreaterThan(
            PrototypePalette.clearPrimaryOpacity,
            PrototypePalette.clearSecondaryOpacity
        )
        XCTAssertGreaterThan(
            PrototypePalette.clearSecondaryOpacity,
            PrototypePalette.clearTertiaryOpacity
        )
        XCTAssertGreaterThanOrEqual(PrototypePalette.clearPrimaryOpacity, 0.95)
        XCTAssertGreaterThanOrEqual(PrototypePalette.clearTertiaryOpacity, 0.85)
    }

    func testClearChartAccentStaysBrightOnDarkBacking() {
        let accent = PrototypePalette.clearChartAccent
        XCTAssertEqual(accent.alpha, 1)
        let luminance = 0.2126 * accent.red + 0.7152 * accent.green + 0.0722 * accent.blue
        XCTAssertGreaterThan(luminance, 0.5)
    }

    func testStandardPaletteKeepsClearTreatmentDisabled() {
        XCTAssertFalse(PrototypePalette.usesClearReadability(for: .system))
        XCTAssertTrue(PrototypePalette.usesClearReadability(for: .clearLight))
    }
}
