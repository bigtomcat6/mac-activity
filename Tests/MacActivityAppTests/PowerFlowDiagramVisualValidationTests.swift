import AppKit
import SwiftUI
import XCTest
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
