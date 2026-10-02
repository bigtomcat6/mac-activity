import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PowerFlowDiagramVisualValidationTests: XCTestCase {
    func testExportVisualMatrixWhenExplicitlyRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("Set MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT to export PNG evidence")
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let fixtures: [(String, PowerFlowDiagramPresentation)] = [
            ("01-one-to-one", PowerFlowDiagramFixtures.oneToOne),
            ("02-one-to-many", PowerFlowDiagramFixtures.oneToMany),
            ("03-many-to-one", PowerFlowDiagramFixtures.manyToOne),
            ("04-many-to-many", PowerFlowDiagramFixtures.manyToMany),
            ("05-grouped", PowerFlowDiagramFixtures.grouped),
            ("06-missing-source", PowerFlowDiagramFixtures.missingSource),
            ("07-waiting", PowerFlowDiagramFixtures.waiting),
            ("08-idle", PowerFlowDiagramFixtures.idle),
            ("09-unavailable", PowerFlowDiagramFixtures.unavailable),
        ]
        let appearances: [(String, DashboardStyleAppearance)] = [
            ("standard", .standardAppearance),
            ("translucent", DashboardPresentationPolicy.translucentAppearance(
                moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
                strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
            )),
        ]
        let colorSchemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

        // Preserve the planned 42-image baseline, including native standard chrome.
        // ImageRenderer may export blank standard-glass interiors on macOS 26;
        // successful PNG encoding is not visual approval of those images.
        for (fixtureName, presentation) in fixtures {
            for (appearanceName, appearance) in appearances {
                for (schemeName, scheme) in colorSchemes {
                    try render(
                        presentation: presentation, width: 384,
                        colorScheme: scheme, appearance: appearance,
                        destination: outputURL.appendingPathComponent(
                            "\(fixtureName)-\(appearanceName)-\(schemeName)-384.png"
                        )
                    )
                }
            }
        }
        for (fixtureName, presentation) in fixtures.prefix(6) {
            try render(
                presentation: presentation, width: 320,
                colorScheme: .light, appearance: .standardAppearance,
                destination: outputURL.appendingPathComponent("\(fixtureName)-standard-light-320.png")
            )
        }

        // Supplemental evidence never replaces or renames a baseline image.
        for (appearanceName, appearance) in appearances {
            for (schemeName, scheme) in colorSchemes {
                try render(
                    presentation: PowerFlowDiagramFixtures.missingSink, width: 320,
                    colorScheme: scheme, appearance: appearance,
                    destination: outputURL.appendingPathComponent(
                        "supplemental-missing-sink-\(appearanceName)-\(schemeName)-320.png"
                    )
                )
            }
        }

        // Localize runtime status/totals as well as builder-owned endpoint titles.
        // Restore the exact in-process override even if rendering or writing throws;
        // do not change persisted app preferences or Foundation's AppleLanguages.
        let previousLanguage = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(previousLanguage) }
        AppLocalization.setPreferredLanguageIdentifier("de")
        let german = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "de"))
        let longGerman = PowerFlowDiagramPresentationBuilder.build(
            snapshot: PowerFlowDiagramFixtures.snapshot(
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(21.46))
            ), isRefreshing: false, bundle: german
        )
        for (appearanceName, appearance) in appearances {
            for (schemeName, scheme) in colorSchemes {
                try render(
                    presentation: longGerman, width: 320,
                    colorScheme: scheme, appearance: appearance,
                    destination: outputURL.appendingPathComponent(
                        "supplemental-long-german-\(appearanceName)-\(schemeName)-320.png"
                    )
                )
            }
        }
    }

    // Not gated behind an env var: the native AppKit drawing appearance must
    // render readable dark-mode text. A non-blank image alone is not evidence.
    func testNativeDarkCaptureKeepsStatusTextLegible() throws {
        let lightBackdrop = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
        let darkBackdrop = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
        let cases: [(String, ColorScheme, NSColor)] = [
            ("light", .light, lightBackdrop),
            ("dark", .dark, darkBackdrop),
        ]
        for (name, scheme, backdrop) in cases {
            guard let image = try nativeCapture(
                presentation: PowerFlowDiagramFixtures.oneToOne, width: 384,
                scheme: scheme, appearance: .standardAppearance, backdrop: backdrop
            ) else {
                XCTFail("native capture unavailable for \(name)")
                continue
            }
            let spread = statusStripLuminanceSpread(image)
            XCTAssertGreaterThan(
                spread, 0.5,
                "\(name) native status text lacks contrast against its surface (spread=\(spread))"
            )
        }
    }

    private func statusStripLuminanceSpread(_ image: NSImage) -> Double {
        regionLuminanceSpread(image, xRange: 0.02...0.98, yRange: 0.05...0.25)
    }

    private struct NativeReadability {
        var status: Double
        var detail: Double
        var isReadable: Bool { status > 0.4 && detail > 0.3 }
    }

    // Non-blank is not readable: a dark capture with black text passes
    // `uniqueColorCount > 1`. Measure actual luminance spread in the status and
    // detail regions instead.
    private func nativeReadability(_ image: NSImage) -> NativeReadability {
        NativeReadability(
            status: regionLuminanceSpread(image, xRange: 0.02...0.98, yRange: 0.05...0.25),
            detail: regionLuminanceSpread(image, xRange: 0.02...0.98, yRange: 0.32...0.95)
        )
    }

    private func regionLuminanceSpread(
        _ image: NSImage,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>
    ) -> Double {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return 0 }
        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        let x0 = max(0, Int(Double(width) * xRange.lowerBound))
        let x1 = min(width, Int(Double(width) * xRange.upperBound))
        let y0 = max(0, Int(Double(height) * yRange.lowerBound))
        let y1 = min(height, Int(Double(height) * yRange.upperBound))
        guard x1 > x0, y1 > y0 else { return 0 }
        var minimum = 1.0
        var maximum = 0.0
        for x in x0..<x1 {
            for y in y0..<y1 {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        return maximum - minimum
    }

    // Bounded after-evidence matrix on opaque light/dark backdrops. Translucent
    // rows are ImageRenderer content flattened onto an opaque backdrop. Standard
    // rows use an NSHostingView/cacheDisplay capture, but macOS 26 `.glassEffect`
    // is neither captured by ImageRenderer nor drawable by `cacheDisplay`, so the
    // native capture substitutes the requested `.perCardRegular` glass kind with
    // `.rootRegular` and flattens onto the opaque backdrop. Those files are named
    // `after-<fixture>-native-content-only-no-glass-<scheme>-384.png`; the real
    // native glass blur background is neither captured nor verified. Each native
    // row is gated by a real status/detail luminance-contrast check and logged as
    // `native-content-only-no-glass CONTENT_READABLE` / `CONTENT_UNREADABLE` /
    // `CONTENT_UNCAPPURABLE` in native-capture-log.txt, whose header repeats that
    // limitation. The SwiftUI `accessibilityReduceTransparency` environment value
    // is read-only on this SDK, so a labelled Reduce Transparency fallback cannot
    // be forced here without changing product policy; that path stays covered by
    // DashboardPresentationPolicy tests.
    func testExportAfterMatrixWhenExplicitlyRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "MACACTIVITY_POWER_FLOW_AFTER_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("Set MACACTIVITY_POWER_FLOW_AFTER_OUTPUT to export after PNG evidence")
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let translucent = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
        let schemes: [(name: String, scheme: ColorScheme, backdrop: Color, nsBackdrop: NSColor)] = [
            ("light", .light, Color(.sRGB, white: 0.93, opacity: 1), NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)),
            ("dark", .dark, Color(.sRGB, white: 0.13, opacity: 1), NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)),
        ]
        let keyFixtures: [(String, PowerFlowDiagramPresentation)] = [
            ("01-one-to-one", PowerFlowDiagramFixtures.oneToOne),
            ("02-one-to-many", PowerFlowDiagramFixtures.oneToMany),
            ("03-many-to-one", PowerFlowDiagramFixtures.manyToOne),
            ("04-many-to-many", PowerFlowDiagramFixtures.manyToMany),
            ("05-grouped", PowerFlowDiagramFixtures.grouped),
        ]
        let supplementalFixtures: [(String, PowerFlowDiagramPresentation)] = [
            ("after-06-battery-only", PowerFlowDiagramFixtures.presentation(endpoints: [
                PowerFlowDiagramFixtures.endpoint(
                    "battery", type: .battery, direction: .input, measurement: .watts(24)
                ),
                PowerFlowDiagramFixtures.endpoint(
                    "mac", type: .mac, direction: .output, measurement: .watts(24)
                ),
            ])),
            ("after-07-known-unavailable", PowerFlowDiagramFixtures.presentation(endpoints: [
                PowerFlowDiagramFixtures.endpoint(
                    "source", type: .usbC, direction: .input, measurement: .unavailable
                ),
                PowerFlowDiagramFixtures.endpoint(
                    "mac", type: .mac, direction: .output, measurement: .watts(24)
                ),
            ])),
            ("after-08-missing-source", PowerFlowDiagramFixtures.missingSource),
            ("after-09-missing-sink", PowerFlowDiagramFixtures.missingSink),
            ("after-10-waiting", PowerFlowDiagramFixtures.waiting),
            ("after-11-idle", PowerFlowDiagramFixtures.idle),
            ("after-12-unavailable", PowerFlowDiagramFixtures.unavailable),
        ]

        // The log starts with the capture-route limitation so no row can be read
        // as native glass validation.
        var nativeLog: [String] = [
            "native-capture-log: content-only evidence, NOT native glass validation.",
            "Route: NSHostingView(rootView:) in a borderless opaque NSWindow, captured with "
                + "bitmapImageRepForCachingDisplay/cacheDisplay, flattened onto the opaque backdrop.",
            "Limitation: `.perCardRegular` glass is substituted with `.rootRegular` for capture; "
                + "real native `.glassEffect` blur/background is NOT captured and NOT verified.",
            "Readability gate: status spread > 0.4 and detail spread > 0.3. Statuses are "
                + "CONTENT_READABLE / CONTENT_UNREADABLE / CONTENT_UNCAPPURABLE.",
        ]
        for (name, presentation) in keyFixtures {
            for entry in schemes {
                try export(
                    label: "after-\(name)-translucent-\(entry.name)-384",
                    presentation: presentation, width: 384, scheme: entry.scheme,
                    appearance: translucent,
                    backdrop: entry.backdrop, outputURL: outputURL
                )
                if let native = try nativeCapture(
                    presentation: presentation, width: 384, scheme: entry.scheme,
                    appearance: .standardAppearance, backdrop: entry.nsBackdrop
                ) {
                    let readability = nativeReadability(native)
                    if readability.isReadable {
                        try writePNG(
                            native,
                            to: outputURL.appendingPathComponent(
                                "after-\(name)-native-content-only-no-glass-\(entry.name)-384.png"
                            )
                        )
                        nativeLog.append(
                            "native-content-only-no-glass CONTENT_READABLE: \(name)-\(entry.name)"
                                + " statusSpread=\(String(format: "%.3f", readability.status))"
                                + " detailSpread=\(String(format: "%.3f", readability.detail))"
                        )
                    } else {
                        nativeLog.append(
                            "native-content-only-no-glass CONTENT_UNREADABLE: \(name)-\(entry.name)"
                                + " statusSpread=\(String(format: "%.3f", readability.status))"
                                + " detailSpread=\(String(format: "%.3f", readability.detail))"
                        )
                    }
                } else {
                    nativeLog.append(
                        "native-content-only-no-glass CONTENT_UNCAPPURABLE: \(name)-\(entry.name)"
                    )
                }
            }
        }

        // 320 pt pressure width for all four expanded topologies plus grouped.
        for (name, presentation) in keyFixtures {
            for entry in schemes {
                try export(
                    label: "after-\(name)-translucent-\(entry.name)-320",
                    presentation: presentation, width: 320, scheme: entry.scheme,
                    appearance: translucent,
                    backdrop: entry.backdrop, outputURL: outputURL
                )
            }
        }

        // Supplemental states (battery-only, known-unavailable, missing sides,
        // waiting/idle/unavailable) at both widths and both schemes. Reuses the
        // existing fixtures where they exist instead of duplicating them.
        for (name, presentation) in supplementalFixtures {
            for width: CGFloat in [384, 320] {
                for entry in schemes {
                    try export(
                        label: "\(name)-translucent-\(entry.name)-\(Int(width))",
                        presentation: presentation, width: width, scheme: entry.scheme,
                        appearance: translucent,
                        backdrop: entry.backdrop, outputURL: outputURL
                    )
                }
            }
        }

        // Increase-Contrast palette: one representative topology, both schemes,
        // using the existing increased-contrast stroke/fill values. The system
        // `colorSchemeContrast` environment value is read-only on this SDK, so the
        // `.increased` contrast branch cannot be forced from the test harness; this
        // is labelled palette evidence, not a claim of forced system contrast.
        let increasedContrast = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacityIncreasedContrast,
            strokeOpacity: DashboardPresentationPolicy.increasedContrastStrokeOpacity
        )
        for entry in schemes {
            try export(
                label: "after-04-many-to-many-increased-contrast-palette-\(entry.name)-384",
                presentation: PowerFlowDiagramFixtures.manyToMany, width: 384,
                scheme: entry.scheme, appearance: increasedContrast,
                backdrop: entry.backdrop, outputURL: outputURL
            )
        }

        // Long localized strings at 320 pt for all four topologies.
        let previousLanguage = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(previousLanguage) }
        AppLocalization.setPreferredLanguageIdentifier("de")
        let german = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "de"))
        for (name, snapshot) in germanTopologySnapshots() {
            let presentation = PowerFlowDiagramPresentationBuilder.build(
                snapshot: snapshot, isRefreshing: false, bundle: german
            )
            for entry in schemes {
                try export(
                    label: "after-long-german-\(name)-translucent-\(entry.name)-320",
                    presentation: presentation, width: 320, scheme: entry.scheme,
                    appearance: translucent,
                    backdrop: entry.backdrop, outputURL: outputURL
                )
            }
        }

        try nativeLog.joined(separator: "\n")
            .write(to: outputURL.appendingPathComponent("native-capture-log.txt"), atomically: true, encoding: .utf8)
    }

    private func germanTopologySnapshots() -> [(String, PowerFlowSnapshot)] {
        [
            ("01-one-to-one", PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(21.46)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(21.46))
            )),
            ("02-one-to-many", PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(56.8)),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30.7)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(26.1))
            )),
            ("03-many-to-one", PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(20)),
                .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(44))
            )),
            ("04-many-to-many", PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(45)),
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
            )),
        ]
    }

    private func export(
        label: String,
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        scheme: ColorScheme,
        appearance: DashboardStyleAppearance,
        backdrop: Color,
        outputURL: URL
    ) throws {
        let content = ZStack {
            backdrop
            PowerFlowDiagramView(presentation: presentation)
                .environment(\.colorScheme, scheme)
                .environment(\.dashboardStyleAppearance, appearance)
                .frame(width: width)
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        try writePNG(image, to: outputURL.appendingPathComponent("\(label).png"))
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }

    private func nativeCapture(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        scheme: ColorScheme,
        appearance: DashboardStyleAppearance,
        backdrop: NSColor
    ) throws -> NSImage? {
        // `.glassEffect` content is not captured by `cacheDisplay` and does not
        // honor the drawing appearance, so the native capture substitutes the
        // requested `.perCardRegular` glass kind with `.rootRegular` (an
        // equivalent glass-free content surface: same system foreground and
        // stroke policy, root instead of nested). Product glass policy is
        // untouched; the exported image is content-on-backdrop and is not a
        // capture of native glass blur.
        var captureAppearance = appearance
        if captureAppearance.glassKind == .perCardRegular {
            captureAppearance.glassKind = .rootRegular
        }
        let view = PowerFlowDiagramView(presentation: presentation)
            .environment(\.colorScheme, scheme)
            .environment(\.dashboardStyleAppearance, captureAppearance)
            .frame(width: width)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: PowerFlowDiagramLayout.cardHeight)
        // Setting the SwiftUI color scheme alone does not affect AppKit's
        // `cacheDisplay` drawing appearance: the window would stay aqua and dark
        // captures would keep black text on the dark surface. Pin the native
        // drawing appearance as well; product foreground/glass policy is untouched.
        let nativeAppearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.appearance = nativeAppearance
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = backdrop
        window.appearance = nativeAppearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        if let nativeAppearance {
            nativeAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: representation)
            }
        } else {
            host.cacheDisplay(in: host.bounds, to: representation)
        }
        let captured = NSImage(size: host.bounds.size)
        captured.addRepresentation(representation)

        // cacheDisplay captures the SwiftUI content but not the macOS 26
        // NSGlassEffectView background, so flatten onto the opaque backdrop to
        // avoid exporting a falsely transparent image. This is content evidence,
        // not a representation of native glass blur.
        let pixelWidth = representation.pixelsWide
        let pixelHeight = representation.pixelsHigh
        guard let flattened = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return captured }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flattened)
        backdrop.setFill()
        NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
        captured.draw(in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
        result.addRepresentation(flattened)
        return result
    }

    private func render(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        colorScheme: ColorScheme,
        appearance: DashboardStyleAppearance,
        destination: URL
    ) throws {
        let renderer = ImageRenderer(content: PowerFlowDiagramView(presentation: presentation)
            .environment(\.colorScheme, colorScheme)
            .environment(\.dashboardStyleAppearance, appearance)
            .frame(width: width))
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: destination, options: .atomic)
    }
}
