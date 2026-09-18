import XCTest
@testable import DebugGlassPrototype

final class PrototypePolicyTests: XCTestCase {
    func testSystemRequirementBoundary() {
        XCTAssertFalse(PrototypePolicy.isSupported(majorVersion: 13))
        XCTAssertFalse(PrototypePolicy.isSupported(majorVersion: 15))
        XCTAssertFalse(PrototypePolicy.isSupported(majorVersion: 25))
        XCTAssertTrue(PrototypePolicy.isSupported(majorVersion: 26))
        XCTAssertTrue(PrototypePolicy.isSupported(majorVersion: 27))
    }

    func testStandardResolutionIsUnchangedByAccessibilityOptions() {
        for reduceTransparency in [false, true] {
            for increaseContrast in [false, true] {
                let resolution = PrototypePolicy.resolve(
                    mode: .standardPopover,
                    reduceTransparency: reduceTransparency,
                    increaseContrast: increaseContrast
                )
                XCTAssertEqual(resolution.requestedMode, .standardPopover)
                XCTAssertEqual(resolution.effectiveMode, .standardPopover)
                XCTAssertEqual(resolution.effectiveHost, .popover)
                XCTAssertEqual(resolution.appearance.glassKind, .regular)
                XCTAssertEqual(resolution.appearance.foreground, .system)
                XCTAssertEqual(resolution.appearance.moduleBackingOpacity, 0)
                XCTAssertEqual(
                    resolution.appearance.strokeOpacity,
                    increaseContrast
                        ? PrototypePolicy.increasedContrastStrokeOpacity
                        : PrototypePolicy.defaultStrokeOpacity
                )
            }
        }
    }

    func testClearModesResolveToClearReadableAppearance() {
        let expectations: [(mode: PrototypeMode, host: PrototypeHostKind)] = [
            (.clearPopover, .popover),
            (.transparentPanel, .panel),
        ]
        for expectation in expectations {
            let resolution = PrototypePolicy.resolve(
                mode: expectation.mode,
                reduceTransparency: false,
                increaseContrast: false
            )
            XCTAssertEqual(resolution.requestedMode, expectation.mode)
            XCTAssertEqual(resolution.effectiveMode, expectation.mode)
            XCTAssertEqual(resolution.effectiveHost, expectation.host)
            XCTAssertEqual(resolution.appearance.glassKind, .clear)
            XCTAssertEqual(resolution.appearance.foreground, .clearLight)
            XCTAssertGreaterThanOrEqual(resolution.appearance.moduleBackingOpacity, 0.65)
            XCTAssertLessThanOrEqual(resolution.appearance.moduleBackingOpacity, 0.75)
        }
    }

    func testIncreaseContrastStrengthensClearBackingAndStroke() {
        for mode in [PrototypeMode.clearPopover, .transparentPanel] {
            let base = PrototypePolicy.resolve(
                mode: mode,
                reduceTransparency: false,
                increaseContrast: false
            )
            let contrast = PrototypePolicy.resolve(
                mode: mode,
                reduceTransparency: false,
                increaseContrast: true
            )
            XCTAssertGreaterThan(
                contrast.appearance.moduleBackingOpacity,
                base.appearance.moduleBackingOpacity
            )
            XCTAssertGreaterThanOrEqual(contrast.appearance.moduleBackingOpacity, 0.8)
            XCTAssertLessThanOrEqual(contrast.appearance.moduleBackingOpacity, 0.95)
            XCTAssertEqual(base.appearance.strokeOpacity, PrototypePolicy.defaultStrokeOpacity)
            XCTAssertEqual(
                contrast.appearance.strokeOpacity,
                PrototypePolicy.increasedContrastStrokeOpacity
            )
        }
    }

    func testReduceTransparencyResolvesClearRequestsToStandardPopover() {
        let standardAppearance = PrototypePolicy.resolve(
            mode: .standardPopover,
            reduceTransparency: false,
            increaseContrast: false
        ).appearance
        for mode in [PrototypeMode.clearPopover, .transparentPanel] {
            let resolution = PrototypePolicy.resolve(
                mode: mode,
                reduceTransparency: true,
                increaseContrast: false
            )
            XCTAssertEqual(resolution.requestedMode, mode)
            XCTAssertEqual(resolution.effectiveMode, .standardPopover)
            XCTAssertEqual(resolution.effectiveHost, .popover)
            XCTAssertEqual(resolution.appearance, standardAppearance)
        }
    }
}

final class PrototypeOptionsTests: XCTestCase {
    func testParsesSmokeTestOptions() throws {
        let options = try PrototypeOptions.parse([
            "--smoke-test", "--json", "--capture-dir", "/tmp/glass", "--cycles", "2",
        ])
        XCTAssertTrue(options.smokeTest)
        XCTAssertEqual(options.captureDirectory, "/tmp/glass")
        XCTAssertEqual(options.cycles, 2)
        XCTAssertFalse(options.backdrop)
    }

    func testParsesBackdropAndHelp() throws {
        XCTAssertTrue(try PrototypeOptions.parse(["--backdrop"]).backdrop)
        XCTAssertTrue(try PrototypeOptions.parse(["--help"]).help)
    }

    func testDefaults() throws {
        XCTAssertEqual(try PrototypeOptions.parse([]), PrototypeOptions())
    }

    func testRejectsUnknownArgumentAndBadValues() {
        XCTAssertThrowsError(try PrototypeOptions.parse(["--nope"]))
        XCTAssertThrowsError(try PrototypeOptions.parse(["--capture-dir"]))
        XCTAssertThrowsError(try PrototypeOptions.parse(["--cycles", "zero"]))
        XCTAssertThrowsError(try PrototypeOptions.parse(["--cycles", "-1"]))
    }
}
