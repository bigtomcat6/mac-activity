import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

// Opt-in visual evidence only. Nothing here runs by default.
//
// `MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT` writes the capturable ImageRenderer
// content matrix. macOS 26 native `.glassEffect` interiors cannot be captured by
// ImageRenderer, so the `standard` rows are rendered through the opaque fallback
// card surface (capturable) and a truthful `metadata.txt` describes the route.
// The `translucent` rows use the capturable root-glass fill route.
//
// `MACACTIVITY_POWER_FLOW_NATIVE_OUTPUT` opens a real borderless NSWindow
// labelled as a synthetic fixture, pins its appearance, and captures the
// on-screen window with `screencapture -l <windowNumber>` so WindowServer
// actually composites the native glass. No `cacheDisplay` and no appearance
// substitution. The window carries mixed widths so grouped and German-320 rows
// share one capture.
//
// `MACACTIVITY_POWER_FLOW_TINT_OUTPUT` captures bounded panel tint candidates
// over the neutral reference backdrop used only to calibrate the product tint.
@MainActor
final class PowerFlowDiagramVisualValidationTests: XCTestCase {
    private typealias Fixtures = PowerFlowDiagramFixtures

    private let fixtures: [(String, PowerFlowDiagramPresentation)] = [
        ("01-one-to-one", Fixtures.reference),
        ("02-one-to-many", Fixtures.oneToMany),
        ("03-many-to-one", Fixtures.manyToOne),
        ("04-many-to-many", Fixtures.manyToMany),
        ("05-grouped", Fixtures.grouped),
        ("06-missing-source", Fixtures.missingSource),
        ("07-missing-sink", Fixtures.missingSink),
        ("08-waiting", Fixtures.waiting),
        ("09-idle", Fixtures.idle),
        ("10-unavailable", Fixtures.unavailable),
        ("11-battery-only", Fixtures.batteryOnly),
        ("12-unknown-input-known-power", Fixtures.knownUnknownInput),
        ("13-unknown-output-known-power", Fixtures.knownUnknownOutput),
        ("14-partial-mixed", Fixtures.partialMixed),
        ("15-unavailable-active", Fixtures.unavailableActive),
        ("16-unbalanced", Fixtures.unbalanced),
        ("17-reference-external", Fixtures.screenshotExternal),
        ("18-reference-battery", Fixtures.screenshotBattery),
        ("19-reference-charging", Fixtures.screenshotCharging),
        ("20-reference-combined", Fixtures.screenshotCombined),
    ]

    func testExportContentMatrixWhenExplicitlyRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("Set MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT to export content matrix PNGs")
        }
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let appearances: [(String, DashboardStyleAppearance)] = [
            ("standard", .standardAppearance),
            ("translucent", DashboardPresentationPolicy.translucentAppearance(
                moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
                strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
            )),
        ]
        let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

        for (name, presentation) in fixtures {
            for (appearanceName, appearance) in appearances {
                for (schemeName, scheme) in schemes {
                    for width: CGFloat in [384, 320] {
                        try render(
                            presentation: presentation, width: width, scheme: scheme,
                            appearance: appearance,
                            destination: outputURL.appendingPathComponent(
                                "\(name)-\(appearanceName)-\(schemeName)-\(Int(width)).png"
                            )
                        )
                    }
                }
            }
        }

        // German pressure width via the capturable root-glass route, all topologies.
        let previousLanguage = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(previousLanguage) }
        AppLocalization.setPreferredLanguageIdentifier("de")
        let german = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "de"))
        let germanRootAppearance = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
        let controlURL = outputURL.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.createDirectory(at: controlURL, withIntermediateDirectories: true)
        for (name, snapshot) in germanTopologySnapshots() {
            let presentation = PowerFlowDiagramPresentationBuilder.build(
                snapshot: snapshot, isRefreshing: false, bundle: german
            )
            for (schemeName, scheme) in schemes {
                let destination = outputURL.appendingPathComponent(
                    "long-german-\(name)-root-\(schemeName)-320.png"
                )
                try render(
                    presentation: presentation, width: 320, scheme: scheme,
                    appearance: germanRootAppearance,
                    destination: destination
                )
                // Meaningful nonblank check: subtract a content-free control with
                // the same backdrop / glass route inside the real text frames, so
                // a dark backdrop alone can never satisfy the assertion.
                let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: 320)
                let regions = textRegions(plan: plan)
                XCTAssertFalse(regions.isEmpty, "\(name) should reserve text frames")
                let controlDestination = controlURL.appendingPathComponent(
                    "long-german-\(name)-root-\(schemeName)-320-control.png"
                )
                try renderControl(
                    presentation: presentation, plan: plan, width: 320, scheme: scheme, appearance: germanRootAppearance,
                    destination: controlDestination
                )
                let contentInk = try textInkContrast(
                    content: destination, control: controlDestination,
                    pointWidth: 320, regions: regions, delta: 0.12
                )
                XCTAssertGreaterThan(
                    contentInk, 60,
                    "German export \(destination.lastPathComponent) text is missing "
                        + "(contrast pixels=\(contentInk))"
                )
            }
        }

        try metadata().write(
            to: outputURL.appendingPathComponent("metadata.txt"), atomically: true, encoding: .utf8
        )
    }

    // Render the production panel at deterministic times. A matte reference
    // surface isolates motion from WindowServer-dependent glass compositing.
    func testExportMotionFramesWhenExplicitlyRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["MACACTIVITY_POWER_FLOW_MOTION_OUTPUT"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set MACACTIVITY_POWER_FLOW_MOTION_OUTPUT to export a full motion cycle")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, presentation) in fixtures {
            let directory = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let width: CGFloat = 384
            let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: width)
            let shape = PowerFlowDiagramSurfaceShape(layout: plan.layout)
            let isScreenshotReference = name.contains("-reference-")
            let surface = isScreenshotReference
                ? Color(white: 0.37) : Color(red: 240 / 255, green: 234 / 255, blue: 234 / 255)
            let backdrop = isScreenshotReference
                ? Color(white: 0.33) : Color(red: 0.86, green: 0.86, blue: 0.87)
            for index in 0..<108 {
                let phase = CGFloat(index) / 108
                let content = PowerFlowDiagramView(presentation: presentation)
                    .panel(plan: plan, phase: phase)
                    .frame(width: width, height: plan.layout.cardFrame.height)
                    .background(shape.fill(surface))
                    .background(backdrop)
                    .environment(\.colorScheme, isScreenshotReference ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(String(format: "frame-%03d.png", index)))
            }
        }
    }

    // One real on-screen window per scheme containing the English reference,
    // grouped and missing-source rows as a labelled synthetic fixture over the
    // neutral reference backdrop. Captured with screencapture so the native glass
    // is composited. German rows live in their own window (below) so the runtime
    // formatter override never leaks into English rows.
    func testExportNativeFixtureWindowWhenExplicitlyRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "MACACTIVITY_POWER_FLOW_NATIVE_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("Set MACACTIVITY_POWER_FLOW_NATIVE_OUTPUT to export native window PNGs")
        }
        _ = NSApplication.shared
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let entries: [NativeEntry] = [
            NativeEntry("01-one-to-one", Fixtures.reference, 384),
            NativeEntry("04-many-to-many", Fixtures.manyToMany, 384),
            NativeEntry("05-grouped", Fixtures.grouped, 384),
            NativeEntry("06-missing-source", Fixtures.missingSource, 320),
        ]

        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let schemeName = scheme == .dark ? "dark" : "light"
            try captureNativeWindow(
                entries: entries, scheme: scheme,
                destination: outputURL.appendingPathComponent("native-mosaic-\(schemeName).png")
            )
            // Clean panel-only 1→1 preview (no fixture labels). 384 pt panel plus
            // a 2 pt margin captures at ~776 px wide on a 2x display.
            try captureNativeSinglePanel(
                presentation: Fixtures.reference, width: 384, scheme: scheme,
                destination: outputURL.appendingPathComponent("native-1to1-\(schemeName).png")
            )
        }

        try exportGermanNativeWindow(outputURL: outputURL)
        try exportGlowCandidates(outputURL: outputURL)
    }

    // Separate German window so runtime values are captured while the in-app
    // language override is active. The previous explicit value is restored with
    // `defer`; nothing is persisted to the Foundation AppleLanguages global.
    private func exportGermanNativeWindow(outputURL: URL) throws {
        let previousLanguage = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(previousLanguage) }
        AppLocalization.setPreferredLanguageIdentifier("de")

        let german = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "de"))
        var entries: [NativeEntry] = []
        for (name, snapshot) in germanTopologySnapshots() {
            entries.append(NativeEntry(
                "german-\(name)-320",
                PowerFlowDiagramPresentationBuilder.build(
                    snapshot: snapshot, isRefreshing: false, bundle: german
                ),
                320
            ))
        }
        for (name, snapshot) in germanPressureSnapshots() {
            entries.append(NativeEntry(
                "german-\(name)-320",
                PowerFlowDiagramPresentationBuilder.build(
                    snapshot: snapshot, isRefreshing: false, bundle: german
                ),
                320
            ))
        }
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            try captureNativeWindow(
                entries: entries, scheme: scheme,
                destination: outputURL.appendingPathComponent(
                    "native-german-\(scheme == .dark ? "dark" : "light").png"
                )
            )
        }
    }

    // Bounded raw-gradient candidates over the neutral reference backdrop; the
    // chosen value is baked into PowerFlowDiagramGlowStyle, not a product knob.
    private func exportGlowCandidates(outputURL: URL) throws {
        let glowURL = outputURL.appendingPathComponent("glow", isDirectory: true)
        try FileManager.default.createDirectory(at: glowURL, withIntermediateDirectories: true)
        let candidates: [(String, Color)] = [
            ("a", Color(red: 0.33, green: 0.635, blue: 1.0)),
            ("b", Color(red: 0.35, green: 0.645, blue: 1.0)),
            ("c", Color(red: 0.37, green: 0.655, blue: 1.0)),
        ]
        for (name, tint) in candidates {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let schemeName = scheme == .dark ? "dark" : "light"
                try captureTintPanel(
                    tintOpacity: scheme == .dark ? 0.10 : 0.20,
                    overlayOpacity: scheme == .dark ? 0 : 0.22,
                    scheme: scheme,
                    destination: glowURL.appendingPathComponent("glow-\(name)-\(schemeName).png"),
                    glowTint: tint
                )
            }
        }
    }

    // German grouped / partial / unbalanced / idle pressure rows. English
    // variants already live in the content matrix.
    private func germanPressureSnapshots() -> [(String, PowerFlowSnapshot)] {
        [
            ("05-grouped", Fixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(45)),
                .init(id: "battery-source", type: .battery, direction: .input, measurement: .watts(12)),
                .init(id: "unknown-source", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
                .init(id: "battery-sink", type: .battery, direction: .output, measurement: .watts(30)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
            )),
            ("06-missing-source", Fixtures.snapshot(
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24))
            )),
            ("07-unbalanced", Fixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(45)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
            )),
            ("08-idle", Fixtures.snapshot(
                .init(id: "battery", type: .battery, direction: .idle, measurement: .watts(0))
            )),
        ]
    }

    // Bounded tint calibration over the neutral reference backdrop. The backdrop
    // color is fixture context only; it is never baked into the product.
    func testExportNativeTintCalibrationWhenExplicitlyRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "MACACTIVITY_POWER_FLOW_TINT_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("Set MACACTIVITY_POWER_FLOW_TINT_OUTPUT to export tint calibration PNGs")
        }
        _ = NSApplication.shared
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for value in [0.12, 0.20, 0.28] {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let name = "tint-\(Int(value * 100))-\(scheme == .dark ? "dark" : "light").png"
                try captureTintPanel(
                    tintOpacity: value, overlayOpacity: 0, scheme: scheme,
                    destination: outputURL.appendingPathComponent(name)
                )
            }
        }
        // Non-opaque calibration layer above the glass, below content.
        for value in [0.14, 0.18, 0.22, 0.26] {
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let name = "overlay-\(Int(value * 100))-\(scheme == .dark ? "dark" : "light").png"
                try captureTintPanel(
                    tintOpacity: 0.20, overlayOpacity: value, scheme: scheme,
                    destination: outputURL.appendingPathComponent(name)
                )
            }
        }
    }

    // MARK: - native capture

    private struct NativeEntry {
        let name: String
        let presentation: PowerFlowDiagramPresentation
        let width: CGFloat
        init(_ name: String, _ presentation: PowerFlowDiagramPresentation, _ width: CGFloat) {
            self.name = name
            self.presentation = presentation
            self.width = width
        }
    }

    private func captureNativeSinglePanel(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        scheme: ColorScheme,
        destination: URL
    ) throws {
        let margin: CGFloat = 2
        let size = CGSize(
            width: width + margin * 2,
            height: PowerFlowDiagramRenderPlan(presentation: presentation, width: width).layout.cardFrame.height + margin * 2
        )
        let content = ZStack {
            PowerFlowNeutralBackdrop()
            PowerFlowDiagramView(presentation: presentation)
                .environment(\.dashboardStyleAppearance, .standardAppearance)
                .environment(\.colorScheme, scheme)
                .frame(width: width)
        }
        .frame(width: size.width, height: size.height)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.51, green: 0.505, blue: 0.535, alpha: 1)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        try capture(window: window, destination: destination)
    }

    private func captureNativeWindow(
        entries: [NativeEntry],
        scheme: ColorScheme,
        destination: URL
    ) throws {
        let margin: CGFloat = 10
        let rowsHeight = entries.reduce(CGFloat(0)) { $0 + PowerFlowDiagramRenderPlan(presentation: $1.presentation, width: $1.width).layout.cardFrame.height }
        let labelHeight: CGFloat = 16
        let labelWidth: CGFloat = 96
        let labelSpacing: CGFloat = 6
        let maxWidth = entries.map(\.width).max() ?? 384
        let width = maxWidth + labelWidth + labelSpacing + margin * 2
        let height = margin * 2 + labelHeight
            + rowsHeight
            + CGFloat(entries.count - 1) * 8

        let content = ZStack(alignment: .topLeading) {
            PowerFlowNeutralBackdrop()
            VStack(alignment: .leading, spacing: 8) {
                Text("Synthetic fixture — neutral backdrop; standardAppearance native glass")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                ForEach(entries, id: \.name) { entry in
                    HStack(spacing: labelSpacing) {
                        Text(entry.name)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .trailing)
                        PowerFlowDiagramView(presentation: entry.presentation)
                            .environment(\.dashboardStyleAppearance, .standardAppearance)
                            .environment(\.colorScheme, scheme)
                            .frame(width: entry.width)
                    }
                }
            }
            .padding(margin)
        }
        .frame(width: width, height: height)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.51, green: 0.505, blue: 0.535, alpha: 1)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        try capture(window: window, destination: destination)
    }

    private func captureTintPanel(
        tintOpacity: Double,
        overlayOpacity: Double,
        scheme: ColorScheme,
        destination: URL,
        glowTint: Color? = nil
    ) throws {
        let width: CGFloat = 384
        let height = PowerFlowDiagramLayout.cardHeight
        let layout = PowerFlowDiagramLayout.resolve(
            width: width, preferredMode: .expanded(.oneToOne), sourceCount: 1, sinkCount: 1
        )
        let shape = PowerFlowDiagramSegmentedShape(
            source: layout.sourceSegment,
            middle: layout.middleSegment,
            sink: layout.sinkSegment,
            radius: layout.outerCornerRadius
        )
        let content = ZStack {
            PowerFlowNeutralBackdrop()
            ZStack {
                if let glowTint {
                    PowerFlowDiagramGlow(middle: layout.middleSegment, tint: glowTint)
                }
            }
            .frame(width: width, height: height)
            .dashboardCardChrome(
                shape: AnyShape(shape),
                glassTint: Color.black.opacity(tintOpacity),
                glassOverlay: overlayOpacity > 0 ? Color.black.opacity(overlayOpacity) : nil
            )
        }
        .frame(width: width, height: height)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.51, green: 0.505, blue: 0.535, alpha: 1)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try capture(window: window, destination: destination)
    }

    private func capture(window: NSWindow, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", String(window.windowNumber), "-x", "-o", destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "screencapture failed for \(destination.lastPathComponent)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "native window capture missing at \(destination.path)"
        )
    }

    private func germanTopologySnapshots() -> [(String, PowerFlowSnapshot)] {
        [
            ("01-one-to-one", Fixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(21.46)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(21.46))
            )),
            ("02-one-to-many", Fixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(56.8)),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30.7)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(26.1))
            )),
            ("03-many-to-one", Fixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(20)),
                .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(44))
            )),
            ("04-many-to-many", Fixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(45)),
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
            )),
        ]
    }

    private func render(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        scheme: ColorScheme,
        appearance: DashboardStyleAppearance,
        destination: URL
    ) throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: width)
        let content = ZStack {
            PowerFlowFixtureBackdrop()
            PowerFlowDiagramView(presentation: presentation)
                .environment(\.colorScheme, scheme)
                .environment(\.dashboardStyleAppearance, appearance)
                // The per-card native glass interior is invisible to ImageRenderer,
                // so the capturable fallback surface is used for the content matrix.
                .environment(\._accessibilityReduceTransparency, !appearance.usesRootGlass)
                .frame(width: width)
        }
        .frame(width: width, height: plan.layout.cardFrame.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        try writePNG(image, to: destination)
    }

    /// Content-free control of the production panel shell (same backdrop, glow
    /// route and glass) used to subtract the route from the German text-region
    /// ink assertion. No product hook.
    private func renderControl(
        presentation: PowerFlowDiagramPresentation,
        plan: PowerFlowDiagramRenderPlan,
        width: CGFloat,
        scheme: ColorScheme,
        appearance: DashboardStyleAppearance,
        destination: URL
    ) throws {
        let shape = PowerFlowDiagramSurfaceShape(layout: plan.layout)
        let content = ZStack {
            PowerFlowFixtureBackdrop()
            ZStack {
                PowerFlowDiagramView(presentation: presentation)
                    .flowLayer(plan: plan, phase: PowerFlowDiagramMotion.restingPhase)
            }
            .frame(width: plan.layout.cardFrame.width, height: plan.layout.cardFrame.height)
            .dashboardCardChrome(
                shape: AnyShape(shape),
                glassTint: PowerFlowDiagramGlassTint.panel(for: scheme),
                glassOverlay: PowerFlowDiagramGlassTint.overlay(for: scheme)
            )
        }
        .frame(width: width, height: plan.layout.cardFrame.height)
        .environment(\.colorScheme, scheme)
        .environment(\.dashboardStyleAppearance, appearance)
        .environment(\._accessibilityReduceTransparency, !appearance.usesRootGlass)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        try writePNG(image, to: destination)
    }

    private func textRegions(plan: PowerFlowDiagramRenderPlan) -> [CGRect] {
        var regions = plan.layout.flowLabelFrames
        if let footer = plan.layout.totalsFooterFrame { regions.append(footer) }
        if regions.isEmpty, let center = plan.layout.groupedCenterFrame { regions = [center] }
        return regions
    }

    /// Counts, inside the real text frames, how many pixels differ from the
    /// content-free control by more than `delta` in luminance. Subtracting the
    /// identical backdrop/glass/glow route means a dark backdrop can never
    /// satisfy the assertion, and the sign of the difference does not matter, so
    /// dark-mode light text is counted as well as light-mode dark text.
    private func textInkContrast(
        content: URL,
        control: URL,
        pointWidth: CGFloat,
        regions: [CGRect],
        delta: CGFloat
    ) throws -> Int {
        let contentRep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: content)))
        let controlRep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: control)))
        XCTAssertEqual(contentRep.pixelsWide, controlRep.pixelsWide, "route mismatch")
        XCTAssertEqual(contentRep.pixelsHigh, controlRep.pixelsHigh, "route mismatch")
        let scale = CGFloat(contentRep.pixelsWide) / pointWidth
        var count = 0
        for region in regions {
            let minX = max(0, Int((region.minX * scale).rounded(.down)))
            let maxX = min(contentRep.pixelsWide - 1, Int((region.maxX * scale).rounded(.up)) - 1)
            let minY = max(0, Int((region.minY * scale).rounded(.down)))
            let maxY = min(contentRep.pixelsHigh - 1, Int((region.maxY * scale).rounded(.up)) - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            for x in minX...maxX {
                for y in minY...maxY {
                    guard let c = contentRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          let k = controlRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    else { continue }
                    if abs(luminance(c) - luminance(k)) > delta { count += 1 }
                }
            }
        }
        return count
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    private func metadata() -> String {
        """
        # Power flow diagram content matrix — truthful route metadata

        standard-*.png   : opaque fallback card surface (content route). The macOS 26
                           native `.glassEffect` interior is NOT captured by ImageRenderer.
        translucent-*.png: root-glass fill route (translucentAppearance), capturable.
        long-german-*-root-*.png: capturable root-glass route at 320 pt (German). The
                           nonblank check subtracts the matching content-free control
                           inside the real text frames (control/long-german-*-control.png).
        native/native-mosaic-*.png: real borderless NSWindow captured with `screencapture -l`,
                           so WindowServer composites the native per-card glass. English rows
                           only; standardAppearance.
        native/native-german-*.png: separate own native window captured while
                           AppLocalization.setPreferredLanguageIdentifier("de") is active
                           (restored with defer; Foundation AppleLanguages is never touched),
                           so runtime values use German decimal separators (21,46 W).
        native/native-1to1-*.png: clean panel-only native capture, no fixture labels; 384 pt
                           panel + 2 pt margin (~776 px wide on a 2x display).
        glow/glow-*-{light,dark}.png: bounded raw-gradient glow candidates over the neutral
                           reference backdrop. The chosen raw tint is baked into
                           PowerFlowDiagramGlowStyle (a constant, not a product knob).
        """
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}

// Fixture context used only by the visual harness. It is never baked into the
// product panel; the panel must reveal this backdrop through its glass.
struct PowerFlowFixtureBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.44, green: 0.40, blue: 0.52),
                Color(red: 0.34, green: 0.32, blue: 0.44),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Neutral gray reference backdrop (~RGB 0.51/0.505/0.535) used to calibrate the
/// panel material tint. Not a product color.
struct PowerFlowNeutralBackdrop: View {
    var body: some View {
        Color(red: 0.51, green: 0.505, blue: 0.535)
    }
}
