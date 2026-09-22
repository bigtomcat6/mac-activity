# Power Flow Diagram Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Energy’s fixed Input/Output lists with a deterministic, accessible power-flow diagram that accepts arbitrary source/sink counts, renders `1→1`, `1→2`, `2→1`, and `2→2` directly, and falls back to a grouped summary for larger or sub-320-point layouts.

**Architecture:** Keep `PowerFlowModel` and all core sampling/calculation code unchanged. Introduce a pure presentation builder that normalizes `PowerFlowSnapshot` into nodes, side summaries, issues, status, and a preferred topology; feed that result into a pure geometry layer and a SwiftUI view using shared-bus semantics. The view reuses existing dashboard chrome, stays fixed-height, localizes every user-facing phrase, and performs no continuous animation.

**Tech Stack:** Swift 6, SwiftUI, AppKit hosting where already used, XCTest, Swift Package Manager, Xcode/XcodeGen, macOS 13 deployment target.

**Spec:** `docs/superpowers/specs/2026-09-22-power-flow-diagram-design.md`

## Global Constraints

- Work on `feat/power-flow-diagram`, based on `next-version`; merge back into `next-version`, not `main`.
- Preserve `macOS 13.0` as the deployment target and add no third-party UI dependency.
- Preserve `PowerFlowModel`’s immediate first read, three-second cadence, cancellation, reset sentinel, and stale-run suppression.
- Do not move sampling, SMC, IOKit, or power-allocation logic into the view.
- Do not use adapter-rated wattage as live power.
- Do not infer residual wattage, hidden sources, hidden sinks, or pairwise source-to-sink allocations.
- Use shared-bus semantics for every multi-source or multi-sink topology.
- Keep lane thickness non-proportional; wattage is communicated by text.
- Render `1→1`, `1→2`, `2→1`, and `2→2` without overlap from 320 through 384 points.
- Select grouped rendering when either active side has more than two visible nodes; width below 320 points may also force grouped rendering.
- Keep the card height stable at 104 points unless visual validation demonstrates a necessary adjustment within the approved 96–108 point range.
- Reuse `dashboardCardChrome()` and `DashboardStyleAppearance`; do not add nested glass effects or a second material system.
- Add no repeating shimmer, particle, timeline, spinner, or other continuous animation.
- Respect Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Color, light/dark appearance, and inactive-window presentation.
- Support all current localizations: `en`, `de`, `fr`, `ja`, `ko`, `zh-Hans`, and `zh-Hant`.
- Preserve existing Power Flow service, model, formatting, localization-completeness, and native-gate tests.

## Review Focus

1. **An endpoint is marked active but reports exactly `0 W`:** Task 3 proves it becomes idle and creates no active topology lane.
2. **Two endpoints reuse the same core ID:** Task 3 proves render IDs remain unique and deterministic after normalization.
3. **Input/output totals sit exactly on the reconciliation tolerance boundary:** Task 4 proves the boundary is accepted and a value just beyond it produces `unbalancedKnownTotals`.
4. **One side is missing while the opposite side has three or more nodes:** Task 4 proves the synthetic Unknown side is retained, grouped mode is selected, no residual wattage is invented, and accessibility includes every real member.
5. **Long localized labels render at 320 points:** Tasks 5 and 6 prove titles may truncate with help text, but wattage labels, lane gaps, and source/flow/sink regions never overlap.

---

## File Structure

### Create

- `Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift`
  - Presentation types, synchronous builder, normalization, sorting, aggregation, issue detection, topology/status selection, and accessibility narration.
- `Sources/MacActivityApp/Views/PowerFlowDiagramLayout.swift`
  - Width thresholds, fixed dimensions, pure frame calculations, lane geometry, and effective render-mode selection.
- `Sources/MacActivityApp/Views/PowerFlowDiagramView.swift`
  - Status row, node tiles, branch/bus shapes, grouped summaries, empty states, palette, motion, and accessibility integration.
- `Tests/MacActivityAppTests/Support/PowerFlowDiagramFixtures.swift`
  - Deterministic snapshots and presentations shared by presentation, layout, and rendering tests.
- `Tests/MacActivityAppTests/PowerFlowDiagramPresentationTests.swift`
- `Tests/MacActivityAppTests/PowerFlowDiagramLayoutTests.swift`
- `Tests/MacActivityAppTests/PowerFlowDiagramViewTests.swift`

### Modify

- `Sources/MacActivityApp/Localization/AppLocalization.swift`
- `Sources/MacActivityApp/Resources/{en,de,fr,ja,ko,zh-Hans,zh-Hant}.lproj/Localizable.strings`
- `Sources/MacActivityApp/Models/PowerFlowPresentation.swift`
- `Sources/MacActivityApp/Views/PowerFlowView.swift`
- `Tests/MacActivityAppTests/LocalizationTests.swift`
- `Tests/MacActivityAppTests/PowerFlowPresentationTests.swift`
- `Tests/MacActivityAppTests/PowerFlowViewTests.swift`
- `MacActivity.xcodeproj/project.pbxproj` — regenerate with XcodeGen; never hand-edit.
- `docs/superpowers/specs/2026-09-22-power-flow-diagram-design.md` — change to “Implemented and verified” only after every applicable gate passes.

### Expected to Remain Behaviorally Unchanged

- `Sources/MacActivityApp/Models/PowerFlowModel.swift`
- `Sources/MacActivityCore/Metrics/Providers/PowerFlowService.swift`
- `Sources/MacActivityCore/Metrics/Providers/SystemPowerFlowReader.swift`
- `Sources/MacActivityCore/Metrics/Providers/PowerFlowSMCReader.swift`
- `Sources/MacActivityCore/Metrics/Providers/PowerFlowTypes.swift`

### Task 1: Establish the localization contract

**Files:**
- Modify: `Sources/MacActivityApp/Localization/AppLocalization.swift`
- Modify: all seven `Sources/MacActivityApp/Resources/*.lproj/Localizable.strings`
- Test: `Tests/MacActivityAppTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: existing `AppLocalization.string(_:_:bundle:)`, bundle discovery, completeness checks, and placeholder-parity checks.
- Produces: the exact localization keys used by Tasks 2, 4, 6, and 7.

- [ ] **Step 1: Write the failing focused localization test**

Add:

```swift
func testPowerFlowDiagramStringsExistForAllSupportedLanguages() throws {
    let keys: [AppLocalization.Key] = [
        .powerFlowUnknownInput,
        .powerFlowUnknownOutput,
        .powerFlowSourcesCount,
        .powerFlowOutputsCount,
        .powerFlowMoreCount,
        .powerFlowPartialData,
        .powerFlowStatusExternalPower,
        .powerFlowStatusBatteryPower,
        .powerFlowStatusCharging,
        .powerFlowStatusMultipleSources,
        .powerFlowStatusMultipleFlows,
        .powerFlowStatusSummary,
        .powerFlowStatusWaiting,
        .powerFlowStatusUnavailable,
        .powerFlowStatusIdle,
        .powerFlowTotals,
        .powerFlowAccessibilityComponent,
        .powerFlowAccessibilityNodeMeasured,
        .powerFlowAccessibilityNodeDerived,
        .powerFlowAccessibilityNodeUnavailable,
        .powerFlowAccessibilitySideSummary,
        .powerFlowAccessibilityAggregateDerived,
        .powerFlowAccessibilityAggregateLowerBound,
        .powerFlowAccessibilityAggregateUnavailable,
        .powerFlowAccessibilityPartialSuffix,
    ]

    for languageIdentifier in AppLocalization.availableLanguageIdentifiers() {
        let bundle = try XCTUnwrap(
            AppLocalization.bundle(forLanguageIdentifier: languageIdentifier)
        )

        for key in keys {
            let value = bundle.localizedString(
                forKey: key.rawValue,
                value: nil,
                table: nil
            )
            XCTAssertNotEqual(
                value,
                key.rawValue,
                "Missing \(key.rawValue) in \(languageIdentifier)"
            )
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(key.rawValue) in \(languageIdentifier) must not be empty"
            )
        }
    }
}
```

- [ ] **Step 2: Run the test and verify the red state**

```bash
swift test \
  --filter LocalizationTests/testPowerFlowDiagramStringsExistForAllSupportedLanguages
```

Expected: compilation fails because the new `AppLocalization.Key` members do not exist.

- [ ] **Step 3: Add the exact key cases**

Append beside the existing `powerFlow.*` cases:

```swift
case powerFlowUnknownInput = "powerFlow.unknownInput"
case powerFlowUnknownOutput = "powerFlow.unknownOutput"
case powerFlowSourcesCount = "powerFlow.sources.count"
case powerFlowOutputsCount = "powerFlow.outputs.count"
case powerFlowMoreCount = "powerFlow.more.count"
case powerFlowPartialData = "powerFlow.partialData"
case powerFlowStatusExternalPower = "powerFlow.status.externalPower"
case powerFlowStatusBatteryPower = "powerFlow.status.batteryPower"
case powerFlowStatusCharging = "powerFlow.status.charging"
case powerFlowStatusMultipleSources = "powerFlow.status.multipleSources"
case powerFlowStatusMultipleFlows = "powerFlow.status.multipleFlows"
case powerFlowStatusSummary = "powerFlow.status.summary"
case powerFlowStatusWaiting = "powerFlow.status.waiting"
case powerFlowStatusUnavailable = "powerFlow.status.unavailable"
case powerFlowStatusIdle = "powerFlow.status.idle"
case powerFlowTotals = "powerFlow.totals"
case powerFlowAccessibilityComponent = "powerFlow.accessibility.component"
case powerFlowAccessibilityNodeMeasured = "powerFlow.accessibility.node.measured"
case powerFlowAccessibilityNodeDerived = "powerFlow.accessibility.node.derived"
case powerFlowAccessibilityNodeUnavailable = "powerFlow.accessibility.node.unavailable"
case powerFlowAccessibilitySideSummary = "powerFlow.accessibility.sideSummary"
case powerFlowAccessibilityAggregateDerived = "powerFlow.accessibility.aggregate.derived"
case powerFlowAccessibilityAggregateLowerBound = "powerFlow.accessibility.aggregate.lowerBound"
case powerFlowAccessibilityAggregateUnavailable = "powerFlow.accessibility.aggregate.unavailable"
case powerFlowAccessibilityPartialSuffix = "powerFlow.accessibility.partialSuffix"
```

- [ ] **Step 4: Add the exact seven-language string blocks**

Append the language-specific blocks from **Appendix A** to the matching `Localizable.strings` files. Preserve every positional placeholder and argument order exactly.

- [ ] **Step 5: Run all localization tests**

```bash
swift test --filter LocalizationTests
```

Expected: all keys exist in every bundle and every non-English format string has the same placeholder sequence as English.

- [ ] **Step 6: Commit**

```bash
git add \
  Sources/MacActivityApp/Localization/AppLocalization.swift \
  Sources/MacActivityApp/Resources/*/Localizable.strings \
  Tests/MacActivityAppTests/LocalizationTests.swift
git commit -m "feat: add power flow diagram localization"
```

### Task 2: Add presentation value types and formatting

**Files:**
- Create: `Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift`
- Modify: `Sources/MacActivityApp/Models/PowerFlowPresentation.swift`
- Test: `Tests/MacActivityAppTests/PowerFlowPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1 localization keys; existing `PowerFlowMeasurement`, `PowerFlowEndpointType`, and `PowerFlowPresentation.powerText`.
- Produces all presentation enums/structs, `PowerFlowPresentation.diagramPowerText`, `PowerFlowPresentation.statusText`, and target-internal `PowerFlowPresentation.endpointTitle`.

- [ ] **Step 1: Write failing display-format tests**

Add:

```swift
func testDiagramPowerTextDistinguishesMeasuredDerivedAndMixedValues() {
    let locale = Locale(identifier: "en")

    XCTAssertEqual(
        PowerFlowPresentation.diagramPowerText(
            .exact(21.46),
            provenance: .measured,
            locale: locale
        ),
        "21.46 W"
    )
    XCTAssertEqual(
        PowerFlowPresentation.diagramPowerText(
            .exact(26.1),
            provenance: .derived,
            locale: locale
        ),
        "≈26.1 W"
    )
    XCTAssertEqual(
        PowerFlowPresentation.diagramPowerText(
            .exact(44),
            provenance: .mixed,
            locale: locale
        ),
        "≈44 W"
    )
}

func testDiagramPowerTextUsesLowerBoundWithoutAmbiguousApproximation() {
    XCTAssertEqual(
        PowerFlowPresentation.diagramPowerText(
            .lowerBound(knownWatts: 57, unavailableCount: 1),
            provenance: .mixed,
            locale: Locale(identifier: "en")
        ),
        "≥57 W"
    )
}

func testDiagramPowerTextUsesDashForUnavailableAndNoLabelForIdle() {
    XCTAssertEqual(
        PowerFlowPresentation.diagramPowerText(
            .unavailable,
            provenance: .measured,
            locale: Locale(identifier: "en")
        ),
        "—"
    )
    XCTAssertNil(
        PowerFlowPresentation.diagramPowerText(
            .idle,
            provenance: .measured,
            locale: Locale(identifier: "en")
        )
    )
}

func testDiagramPowerTextUsesLocalizedDecimalSeparator() {
    XCTAssertEqual(
        PowerFlowPresentation.diagramPowerText(
            .exact(21.46),
            provenance: .measured,
            locale: Locale(identifier: "de_DE")
        ),
        "21,46 W"
    )
}
```

- [ ] **Step 2: Verify the red state**

```bash
swift test --filter PowerFlowPresentationTests/testDiagramPowerText
```

Expected: compilation fails because the diagram types and formatter do not exist.

- [ ] **Step 3: Create the exact presentation type surface**

Create `PowerFlowDiagramPresentation.swift`:

```swift
import Foundation
import MacActivityCore

struct PowerFlowDiagramPresentation: Equatable, Sendable {
    var preferredMode: PowerFlowDiagramMode
    var sources: [PowerFlowDiagramNode]
    var sinks: [PowerFlowDiagramNode]
    var idleEndpoints: [PowerFlowDiagramNode]
    var sourceSummary: PowerFlowDiagramSideSummary
    var sinkSummary: PowerFlowDiagramSideSummary
    var issues: Set<PowerFlowDiagramIssue>
    var status: PowerFlowDiagramStatus
    var accessibilityLabel: String
}

enum PowerFlowDiagramMode: Equatable, Sendable {
    case waiting
    case idle
    case expanded(PowerFlowDiagramTopology)
    case grouped
    case unavailable
}

enum PowerFlowDiagramTopology: Equatable, Sendable {
    case oneToOne
    case oneToMany
    case manyToOne
    case manyToMany
}

struct PowerFlowDiagramNode: Identifiable, Equatable, Sendable {
    var id: String
    var kind: PowerFlowDiagramNodeKind
    var title: String
    var measurement: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var isSynthetic: Bool
}

struct PowerFlowDiagramSideSummary: Equatable, Sendable {
    var memberCount: Int
    var total: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var representatives: [PowerFlowDiagramNode]
}

enum PowerFlowDiagramNodeKind: Equatable, Hashable, Sendable {
    case externalPower
    case battery
    case mac
    case other
    case unknown
}

enum PowerFlowDisplayMeasurement: Equatable, Sendable {
    case exact(Double)
    case lowerBound(knownWatts: Double, unavailableCount: Int)
    case unavailable
    case idle

    var exactWatts: Double? {
        guard case .exact(let watts) = self else { return nil }
        return watts
    }
}

enum PowerFlowDisplayProvenance: Equatable, Hashable, Sendable {
    case measured
    case derived
    case mixed
    case absent
}

enum PowerFlowDiagramStatus: Equatable, Sendable {
    case waiting
    case idle
    case unavailable
    case externalPower
    case batteryPower
    case charging
    case multipleSources
    case multipleFlows
    case summary
}

enum PowerFlowDiagramIssue: Equatable, Hashable, Sendable {
    case missingSource
    case missingSink
    case missingMeasurements
    case unbalancedKnownTotals
    case unresolvedIdleMeasurement
}
```

- [ ] **Step 4: Extend the existing formatter**

In `PowerFlowPresentation.swift`:

1. Change `private static func endpointTitle` to target-internal `static func endpointTitle`.
2. Add:

```swift
static func diagramPowerText(
    _ measurement: PowerFlowDisplayMeasurement,
    provenance: PowerFlowDisplayProvenance,
    locale: Locale,
    bundle: Bundle? = nil
) -> String? {
    switch measurement {
    case .exact(let watts):
        let value = powerText(.watts(watts), locale: locale, bundle: bundle)
        switch provenance {
        case .derived, .mixed:
            return "≈\(value)"
        case .measured, .absent:
            return value
        }

    case .lowerBound(let knownWatts, _):
        let value = powerText(
            .watts(knownWatts),
            locale: locale,
            bundle: bundle
        )
        return "≥\(value)"

    case .unavailable:
        return "—"

    case .idle:
        return nil
    }
}

static func statusText(
    _ status: PowerFlowDiagramStatus,
    bundle: Bundle? = nil
) -> String {
    switch status {
    case .waiting:
        return AppLocalization.string(.powerFlowStatusWaiting, bundle: bundle)
    case .idle:
        return AppLocalization.string(.powerFlowStatusIdle, bundle: bundle)
    case .unavailable:
        return AppLocalization.string(.powerFlowStatusUnavailable, bundle: bundle)
    case .externalPower:
        return AppLocalization.string(.powerFlowStatusExternalPower, bundle: bundle)
    case .batteryPower:
        return AppLocalization.string(.powerFlowStatusBatteryPower, bundle: bundle)
    case .charging:
        return AppLocalization.string(.powerFlowStatusCharging, bundle: bundle)
    case .multipleSources:
        return AppLocalization.string(.powerFlowStatusMultipleSources, bundle: bundle)
    case .multipleFlows:
        return AppLocalization.string(.powerFlowStatusMultipleFlows, bundle: bundle)
    case .summary:
        return AppLocalization.string(.powerFlowStatusSummary, bundle: bundle)
    }
}
```

- [ ] **Step 5: Run the complete presentation-format suite**

```bash
swift test --filter PowerFlowPresentationTests
```

Expected: existing row-format tests and all new diagram-format tests pass.

- [ ] **Step 6: Commit**

```bash
git add \
  Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift \
  Sources/MacActivityApp/Models/PowerFlowPresentation.swift \
  Tests/MacActivityAppTests/PowerFlowPresentationTests.swift
git commit -m "feat: define power flow diagram presentation values"
```

### Task 3: Normalize endpoints, preserve identity, and build side summaries

**Files:**
- Modify: `Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift`
- Create: `Tests/MacActivityAppTests/Support/PowerFlowDiagramFixtures.swift`
- Create: `Tests/MacActivityAppTests/PowerFlowDiagramPresentationTests.swift`

**Interfaces:**
- Consumes: Task 2 presentation types and `PowerFlowPresentation.endpointTitle`.
- Produces:
  - `PowerFlowDiagramPresentationBuilder.normalize(snapshot:bundle:)`
  - `PowerFlowDiagramPresentationBuilder.sideSummary(for:)`
  - deterministic unique render IDs;
  - normalized sources, sinks, idle endpoints, and normalization issues.

- [ ] **Step 1: Create reusable fixtures**

Create:

```swift
import Foundation
@testable import MacActivityCore
@testable import MacActivityApp

enum PowerFlowDiagramFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
    }

    static func endpoint(
        _ id: String,
        type: PowerFlowEndpointType,
        direction: PowerFlowDirection,
        measurement: PowerFlowMeasurement
    ) -> PowerFlowEndpoint {
        PowerFlowEndpoint(
            id: id,
            type: type,
            direction: direction,
            measurement: measurement
        )
    }

    static func snapshot(
        _ endpoints: [PowerFlowEndpoint],
        timestamp: Date = timestamp
    ) -> PowerFlowSnapshot {
        PowerFlowSnapshot(timestamp: timestamp, endpoints: endpoints)
    }

    static func snapshot(
        _ endpoints: PowerFlowEndpoint...,
        timestamp: Date = timestamp
    ) -> PowerFlowSnapshot {
        snapshot(endpoints, timestamp: timestamp)
    }
}
```

- [ ] **Step 2: Write failing normalization tests**

Create `PowerFlowDiagramPresentationTests.swift` and cover these exact assertions:

```swift
@MainActor
final class PowerFlowDiagramPresentationTests: XCTestCase {
    func testUnknownIdentityWithExactPowerRemainsAnActiveSource() {
        let content = normalize(
            .init(
                id: "mystery",
                type: .unknownExternalInterface,
                direction: .input,
                measurement: .watts(12)
            )
        )

        XCTAssertEqual(content.sources.count, 1)
        XCTAssertEqual(content.sources[0].kind, .unknown)
        XCTAssertEqual(content.sources[0].measurement, .exact(12))
        XCTAssertEqual(content.sources[0].provenance, .measured)
        XCTAssertFalse(content.issues.contains(.missingMeasurements))
    }

    func testKnownActiveEndpointWithUnavailablePowerIsPreservedAndFlagged() {
        let content = normalize(
            .init(
                id: "usb-c",
                type: .usbC,
                direction: .input,
                measurement: .unavailable
            )
        )

        XCTAssertEqual(content.sources.map(\.title), ["USB-C"])
        XCTAssertEqual(content.sources.map(\.measurement), [.unavailable])
        XCTAssertTrue(content.issues.contains(.missingMeasurements))
    }

    func testActiveZeroWattEndpointBecomesIdleAndCreatesNoActiveLane() {
        let content = normalize(
            .init(
                id: "external",
                type: .usbC,
                direction: .input,
                measurement: .watts(0)
            )
        )

        XCTAssertTrue(content.sources.isEmpty)
        XCTAssertTrue(content.sinks.isEmpty)
        XCTAssertEqual(content.idleEndpoints.map(\.measurement), [.idle])
    }

    func testIdleUnavailableEndpointDoesNotPretendToBeConfirmedZero() {
        let content = normalize(
            .init(
                id: "battery",
                type: .battery,
                direction: .idle,
                measurement: .unavailable
            )
        )

        XCTAssertEqual(content.idleEndpoints.map(\.measurement), [.unavailable])
        XCTAssertTrue(content.issues.contains(.unresolvedIdleMeasurement))
    }

    func testNonFiniteAndNegativeDefensiveValuesBecomeUnavailable() {
        for value in [Double.nan, Double.infinity, -1.0] {
            let content = normalize(
                .init(
                    id: "bad",
                    type: .usbC,
                    direction: .input,
                    measurement: .watts(value)
                )
            )

            XCTAssertEqual(content.sources.first?.measurement, .unavailable)
            XCTAssertTrue(content.issues.contains(.missingMeasurements))
        }
    }

    func testMacPowerIsMarkedDerived() {
        let content = normalize(
            .init(
                id: "mac",
                type: .mac,
                direction: .output,
                measurement: .watts(26.1)
            )
        )

        XCTAssertEqual(content.sinks.first?.provenance, .derived)
    }

    func testOrderingIsIndependentOfSnapshotOrder() {
        let endpoints = [
            PowerFlowDiagramFixtures.endpoint(
                "unknown",
                type: .unknownExternalInterface,
                direction: .input,
                measurement: .watts(30)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "battery",
                type: .battery,
                direction: .input,
                measurement: .watts(24)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "usb-low",
                type: .usbC,
                direction: .input,
                measurement: .watts(20)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "usb-high",
                type: .usbC,
                direction: .input,
                measurement: .watts(45)
            ),
        ]

        let forward = PowerFlowDiagramPresentationBuilder.normalize(
            snapshot: PowerFlowDiagramFixtures.snapshot(endpoints),
            bundle: PowerFlowDiagramFixtures.englishBundle
        )
        let reversed = PowerFlowDiagramPresentationBuilder.normalize(
            snapshot: PowerFlowDiagramFixtures.snapshot(Array(endpoints.reversed())),
            bundle: PowerFlowDiagramFixtures.englishBundle
        )

        XCTAssertEqual(forward.sources, reversed.sources)
        XCTAssertEqual(
            forward.sources.map(\.measurement),
            [.exact(45), .exact(20), .exact(24), .exact(30)]
        )
    }

    func testDuplicateCoreIDsReceiveUniqueDeterministicRenderIDs() {
        let endpoints = [
            PowerFlowDiagramFixtures.endpoint(
                "duplicate",
                type: .usbC,
                direction: .input,
                measurement: .watts(45)
            ),
            PowerFlowDiagramFixtures.endpoint(
                "duplicate",
                type: .usbC,
                direction: .input,
                measurement: .watts(12)
            ),
        ]

        let forward = normalized(endpoints)
        let reversed = normalized(Array(endpoints.reversed()))

        XCTAssertEqual(forward.sources.map(\.id), reversed.sources.map(\.id))
        XCTAssertEqual(Set(forward.sources.map(\.id)).count, 2)
    }

    func testSideSummaryProducesExactLowerBoundAndUnavailableTotals() {
        let exact = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            node("one", .exact(20), .measured),
            node("two", .exact(24), .derived),
        ])
        let partial = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            node("one", .exact(20), .measured),
            node("two", .exact(24), .derived),
            node("three", .unavailable, .measured),
        ])
        let unavailable = PowerFlowDiagramPresentationBuilder.sideSummary(for: [
            node("four", .unavailable, .measured),
            node("five", .unavailable, .derived),
        ])

        XCTAssertEqual(exact.total, .exact(44))
        XCTAssertEqual(exact.provenance, .mixed)
        XCTAssertEqual(
            partial.total,
            .lowerBound(knownWatts: 44, unavailableCount: 1)
        )
        XCTAssertEqual(partial.representatives.map(\.id), ["one", "two"])
        XCTAssertEqual(unavailable.total, .unavailable)
    }

    private func normalize(
        _ endpoint: PowerFlowEndpoint
    ) -> PowerFlowDiagramNormalizedContent {
        normalized([endpoint])
    }

    private func normalized(
        _ endpoints: [PowerFlowEndpoint]
    ) -> PowerFlowDiagramNormalizedContent {
        PowerFlowDiagramPresentationBuilder.normalize(
            snapshot: PowerFlowDiagramFixtures.snapshot(endpoints),
            bundle: PowerFlowDiagramFixtures.englishBundle
        )
    }

    private func node(
        _ id: String,
        _ measurement: PowerFlowDisplayMeasurement,
        _ provenance: PowerFlowDisplayProvenance
    ) -> PowerFlowDiagramNode {
        PowerFlowDiagramNode(
            id: id,
            kind: .other,
            title: id,
            measurement: measurement,
            provenance: provenance,
            isSynthetic: false
        )
    }
}
```

- [ ] **Step 3: Verify the red state**

```bash
swift test --filter PowerFlowDiagramPresentationTests
```

Expected: compilation fails because the builder, normalized content, and side-summary functions do not exist.

- [ ] **Step 4: Add normalization support types**

```swift
struct PowerFlowDiagramNormalizedContent: Equatable, Sendable {
    var sources: [PowerFlowDiagramNode]
    var sinks: [PowerFlowDiagramNode]
    var idleEndpoints: [PowerFlowDiagramNode]
    var issues: Set<PowerFlowDiagramIssue>
}

private struct PowerFlowDiagramNodeCandidate {
    var baseID: String
    var kind: PowerFlowDiagramNodeKind
    var title: String
    var measurement: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var isSynthetic: Bool
}

private enum PowerFlowDiagramSide: String {
    case source
    case sink
    case idle
}
```

- [ ] **Step 5: Implement sanitization, classification, mapping, sorting, and IDs**

Add `PowerFlowDiagramPresentationBuilder` with:

```swift
enum PowerFlowDiagramPresentationBuilder {
    static func normalize(
        snapshot: PowerFlowSnapshot,
        bundle: Bundle? = nil
    ) -> PowerFlowDiagramNormalizedContent {
        var sources = [PowerFlowDiagramNodeCandidate]()
        var sinks = [PowerFlowDiagramNodeCandidate]()
        var idle = [PowerFlowDiagramNodeCandidate]()
        var issues = Set<PowerFlowDiagramIssue>()

        for endpoint in snapshot.endpoints {
            let measurement = sanitized(endpoint.measurement)
            let direction: PowerFlowDirection =
                measurement == .exact(0) ? .idle : endpoint.direction
            let candidate = candidate(
                endpoint,
                measurement: direction == .idle && measurement == .exact(0)
                    ? .idle
                    : measurement,
                bundle: bundle
            )

            switch direction {
            case .input:
                sources.append(candidate)
                if measurement == .unavailable {
                    issues.insert(.missingMeasurements)
                }
            case .output:
                sinks.append(candidate)
                if measurement == .unavailable {
                    issues.insert(.missingMeasurements)
                }
            case .idle:
                idle.append(candidate)
                if measurement == .unavailable {
                    issues.insert(.unresolvedIdleMeasurement)
                }
            }
        }

        return PowerFlowDiagramNormalizedContent(
            sources: finalized(sources, side: .source),
            sinks: finalized(sinks, side: .sink),
            idleEndpoints: finalized(idle, side: .idle),
            issues: issues
        )
    }

    private static func sanitized(
        _ measurement: PowerFlowMeasurement
    ) -> PowerFlowDisplayMeasurement {
        switch measurement {
        case .unavailable:
            return .unavailable
        case .watts(let watts):
            guard watts.isFinite, watts >= 0 else {
                return .unavailable
            }
            return .exact(watts)
        }
    }

    private static func candidate(
        _ endpoint: PowerFlowEndpoint,
        measurement: PowerFlowDisplayMeasurement,
        bundle: Bundle?
    ) -> PowerFlowDiagramNodeCandidate {
        PowerFlowDiagramNodeCandidate(
            baseID: endpoint.id,
            kind: nodeKind(endpoint.type),
            title: PowerFlowPresentation.endpointTitle(
                endpoint.type,
                bundle: bundle
            ),
            measurement: measurement,
            provenance: endpoint.type == .mac ? .derived : .measured,
            isSynthetic: false
        )
    }

    private static func nodeKind(
        _ type: PowerFlowEndpointType
    ) -> PowerFlowDiagramNodeKind {
        switch type {
        case .usbC, .magSafe: return .externalPower
        case .battery: return .battery
        case .mac: return .mac
        case .unknownExternalInterface: return .unknown
        }
    }
}
```

Implement deterministic ordering with an explicit comparator:

```swift
private static func finalized(
    _ candidates: [PowerFlowDiagramNodeCandidate],
    side: PowerFlowDiagramSide
) -> [PowerFlowDiagramNode] {
    let sorted = candidates.sorted {
        comesBefore($0, $1, side: side)
    }
    var occurrences = [String: Int]()

    return sorted.map { candidate in
        let base = "\(side.rawValue):\(candidate.baseID)"
        let occurrence = occurrences[base, default: 0]
        occurrences[base] = occurrence + 1

        return PowerFlowDiagramNode(
            id: occurrence == 0 ? base : "\(base)#\(occurrence + 1)",
            kind: candidate.kind,
            title: candidate.title,
            measurement: candidate.measurement,
            provenance: candidate.provenance,
            isSynthetic: candidate.isSynthetic
        )
    }
}

private static func comesBefore(
    _ lhs: PowerFlowDiagramNodeCandidate,
    _ rhs: PowerFlowDiagramNodeCandidate,
    side: PowerFlowDiagramSide
) -> Bool {
    let lhsRank = kindRank(lhs.kind, side: side)
    let rhsRank = kindRank(rhs.kind, side: side)
    if lhsRank != rhsRank { return lhsRank < rhsRank }
    if lhs.isSynthetic != rhs.isSynthetic { return !lhs.isSynthetic }

    let lhsWatts = lhs.measurement.exactWatts
    let rhsWatts = rhs.measurement.exactWatts
    if (lhsWatts != nil) != (rhsWatts != nil) {
        return lhsWatts != nil
    }
    if let lhsWatts, let rhsWatts, lhsWatts != rhsWatts {
        return lhsWatts > rhsWatts
    }
    if lhs.baseID != rhs.baseID { return lhs.baseID < rhs.baseID }
    return lhs.title < rhs.title
}
```

Use these rank tables:

```swift
private static func kindRank(
    _ kind: PowerFlowDiagramNodeKind,
    side: PowerFlowDiagramSide
) -> Int {
    switch side {
    case .source, .idle:
        switch kind {
        case .externalPower: return 0
        case .battery: return 1
        case .other: return 2
        case .unknown: return 3
        case .mac: return 4
        }
    case .sink:
        switch kind {
        case .battery: return 0
        case .mac: return 1
        case .other: return 2
        case .unknown: return 3
        case .externalPower: return 4
        }
    }
}
```

- [ ] **Step 6: Implement side summaries**

```swift
static func sideSummary(
    for nodes: [PowerFlowDiagramNode]
) -> PowerFlowDiagramSideSummary {
    let real = nodes.filter { !$0.isSynthetic }
    let known = real.compactMap(\.measurement.exactWatts)
    let unavailableCount = real.count - known.count

    let total: PowerFlowDisplayMeasurement
    if real.isEmpty {
        total = nodes.isEmpty ? .idle : .unavailable
    } else if known.isEmpty {
        total = .unavailable
    } else if unavailableCount > 0 {
        total = .lowerBound(
            knownWatts: known.reduce(0, +),
            unavailableCount: unavailableCount
        )
    } else {
        total = .exact(known.reduce(0, +))
    }

    let provenances = Set(real.map(\.provenance))
    let provenance: PowerFlowDisplayProvenance
    if real.isEmpty {
        provenance = .absent
    } else if provenances.count == 1 {
        provenance = provenances.first!
    } else {
        provenance = .mixed
    }

    return PowerFlowDiagramSideSummary(
        memberCount: nodes.count,
        total: total,
        provenance: provenance,
        representatives: Array(nodes.prefix(2))
    )
}
```

- [ ] **Step 7: Run the suite**

```bash
swift test --filter PowerFlowDiagramPresentationTests
```

Expected: all Task 3 tests pass, including zero-watt normalization, duplicate-ID uniqueness, stable ordering, and lower-bound aggregation.

- [ ] **Step 8: Commit**

```bash
git add \
  Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift \
  Tests/MacActivityAppTests/Support/PowerFlowDiagramFixtures.swift \
  Tests/MacActivityAppTests/PowerFlowDiagramPresentationTests.swift
git commit -m "feat: normalize power flow diagram endpoints"
```

### Task 4: Assemble topology, placeholders, issues, status, and accessibility

**Files:**
- Modify: `Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift`
- Modify: `Tests/MacActivityAppTests/PowerFlowDiagramPresentationTests.swift`

**Interfaces:**
- Consumes: Task 3 `normalize(snapshot:bundle:)` and `sideSummary(for:)`.
- Produces:

```swift
PowerFlowDiagramPresentationBuilder.build(
    snapshot: PowerFlowSnapshot,
    isRefreshing: Bool,
    bundle: Bundle? = nil
) -> PowerFlowDiagramPresentation
```

Tasks 5–7 consume only the resulting presentation and must not re-derive topology from `PowerFlowSnapshot`.

- [ ] **Step 1: Write failing topology and grouped-mode tests**

Add:

```swift
func testBuildSelectsAllFourExpandedTopologies() {
    let cases: [(PowerFlowSnapshot, PowerFlowDiagramMode)] = [
        (
            PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(21.46)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(21.46))
            ),
            .expanded(.oneToOne)
        ),
        (
            PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(56.8)),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30.7)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(26.1))
            ),
            .expanded(.oneToMany)
        ),
        (
            PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(20)),
                .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(44))
            ),
            .expanded(.manyToOne)
        ),
        (
            PowerFlowDiagramFixtures.snapshot(
                .init(id: "source", type: .usbC, direction: .input, measurement: .watts(45)),
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(12)),
                .init(id: "battery", type: .battery, direction: .output, measurement: .watts(30)),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
            ),
            .expanded(.manyToMany)
        ),
    ]

    for (snapshot, expected) in cases {
        XCTAssertEqual(build(snapshot).preferredMode, expected)
    }
}

func testMoreThanTwoNodesOnEitherSideUsesGroupedMode() {
    let threeSources = PowerFlowDiagramFixtures.snapshot(
        .init(id: "one", type: .usbC, direction: .input, measurement: .watts(20)),
        .init(id: "two", type: .battery, direction: .input, measurement: .watts(10)),
        .init(id: "three", type: .unknownExternalInterface, direction: .input, measurement: .watts(5)),
        .init(id: "mac", type: .mac, direction: .output, measurement: .watts(35))
    )
    let threeSinks = PowerFlowDiagramFixtures.snapshot(
        .init(id: "source", type: .usbC, direction: .input, measurement: .watts(35)),
        .init(id: "battery", type: .battery, direction: .output, measurement: .watts(10)),
        .init(id: "mac", type: .mac, direction: .output, measurement: .watts(20)),
        .init(id: "unknown", type: .unknownExternalInterface, direction: .output, measurement: .watts(5))
    )

    XCTAssertEqual(build(threeSources).preferredMode, .grouped)
    XCTAssertEqual(build(threeSinks).preferredMode, .grouped)
}
```

- [ ] **Step 2: Write failing missing-side and terminal-state tests**

```swift
func testMissingSourceInsertsNonNumericUnknownInput() {
    let presentation = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24))
        )
    )

    XCTAssertEqual(presentation.preferredMode, .expanded(.oneToOne))
    XCTAssertEqual(presentation.sources.map(\.title), ["Unknown Input"])
    XCTAssertEqual(presentation.sources.map(\.measurement), [.unavailable])
    XCTAssertTrue(presentation.sources[0].isSynthetic)
    XCTAssertEqual(presentation.sourceSummary.total, .unavailable)
    XCTAssertTrue(presentation.issues.contains(.missingSource))
    XCTAssertFalse(presentation.sources.contains { $0.measurement == .exact(24) })
}

func testMissingSinkInsertsNonNumericUnknownOutput() {
    let presentation = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(24))
        )
    )

    XCTAssertEqual(presentation.sinks.map(\.title), ["Unknown Output"])
    XCTAssertEqual(presentation.sinks.map(\.measurement), [.unavailable])
    XCTAssertTrue(presentation.sinks[0].isSynthetic)
    XCTAssertTrue(presentation.issues.contains(.missingSink))
}

func testMissingSourceWithThreeSinksRemainsGroupedAndNarratesEveryMember() {
    let presentation = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "battery", type: .battery, direction: .output, measurement: .watts(10)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(20)),
            .init(id: "unknown", type: .unknownExternalInterface, direction: .output, measurement: .unavailable)
        )
    )

    XCTAssertEqual(presentation.preferredMode, .grouped)
    XCTAssertEqual(presentation.sources.map(\.title), ["Unknown Input"])
    XCTAssertEqual(presentation.sinks.count, 3)
    XCTAssertTrue(presentation.issues.contains(.missingSource))
    XCTAssertTrue(presentation.accessibilityLabel.contains("Battery"))
    XCTAssertTrue(presentation.accessibilityLabel.contains("Mac"))
    XCTAssertTrue(
        presentation.accessibilityLabel.contains(
            "Unknown external interface"
        )
    )
    XCTAssertFalse(
        presentation.sources.contains { $0.measurement.exactWatts != nil }
    )
}

func testWaitingIdleAndUnavailableModesAreDistinct() {
    let waiting = PowerFlowDiagramPresentationBuilder.build(
        snapshot: .empty,
        isRefreshing: true,
        bundle: PowerFlowDiagramFixtures.englishBundle
    )
    let idle = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "battery", type: .battery, direction: .idle, measurement: .watts(0))
        )
    )
    let unavailable = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "battery", type: .battery, direction: .idle, measurement: .unavailable)
        )
    )

    XCTAssertEqual(waiting.preferredMode, .waiting)
    XCTAssertEqual(idle.preferredMode, .idle)
    XCTAssertEqual(unavailable.preferredMode, .unavailable)
}
```

- [ ] **Step 3: Write failing status, tolerance, residual, and narration tests**

```swift
func testStatusPrecedenceMatchesOperatingPattern() {
    let charging = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(40)),
            .init(id: "battery", type: .battery, direction: .output, measurement: .watts(18)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(22))
        )
    )
    let batteryPower = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24))
        )
    )
    let multipleSources = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "external", type: .usbC, direction: .input, measurement: .watts(20)),
            .init(id: "battery", type: .battery, direction: .input, measurement: .watts(24)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(44))
        )
    )
    let missingSide = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(24))
        )
    )

    XCTAssertEqual(charging.status, .charging)
    XCTAssertEqual(batteryPower.status, .batteryPower)
    XCTAssertEqual(multipleSources.status, .multipleSources)
    XCTAssertEqual(missingSide.status, .summary)
}

func testKnownTotalToleranceBoundaryIsAcceptedAndJustBeyondIsFlagged() {
    let atBoundary = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(20)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(19))
        )
    )
    let beyond = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(20)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(18.99))
        )
    )

    XCTAssertFalse(atBoundary.issues.contains(.unbalancedKnownTotals))
    XCTAssertTrue(beyond.issues.contains(.unbalancedKnownTotals))
}

func testUnbalancedTotalsNeverCreateAResidualNode() {
    let presentation = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "source", type: .usbC, direction: .input, measurement: .watts(57)),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(27))
        )
    )

    XCTAssertEqual(presentation.sources.count, 1)
    XCTAssertEqual(presentation.sinks.count, 1)
    XCTAssertTrue(presentation.issues.contains(.unbalancedKnownTotals))
    XCTAssertFalse(presentation.sources.contains(where: \.isSynthetic))
    XCTAssertFalse(presentation.sinks.contains(where: \.isSynthetic))
}

func testGroupedPartialAggregateHasExactEnglishNarration() {
    let presentation = build(
        PowerFlowDiagramFixtures.snapshot(
            .init(id: "one", type: .usbC, direction: .input, measurement: .watts(45)),
            .init(id: "two", type: .battery, direction: .input, measurement: .watts(12)),
            .init(id: "three", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
            .init(id: "mac", type: .mac, direction: .output, measurement: .watts(57))
        )
    )

    XCTAssertEqual(
        presentation.sourceSummary.total,
        .lowerBound(knownWatts: 57, unavailableCount: 1)
    )
    XCTAssertEqual(
        presentation.accessibilityLabel,
        "Power Flow Summary. Input: Total: at least 57 W; unavailable readings: 1. "
            + "USB-C, 45 W; Battery, 12 W; Unknown external interface, power unavailable. "
            + "Output: Total: approximately 57 W. Mac, approximately 57 W. Partial data."
    )
}
```

Add this test helper:

```swift
private func build(
    _ snapshot: PowerFlowSnapshot
) -> PowerFlowDiagramPresentation {
    PowerFlowDiagramPresentationBuilder.build(
        snapshot: snapshot,
        isRefreshing: false,
        bundle: PowerFlowDiagramFixtures.englishBundle
    )
}
```

- [ ] **Step 4: Verify the red state**

```bash
swift test --filter PowerFlowDiagramPresentationTests
```

Expected: compilation fails because `build(...)` and final presentation assembly do not exist.

- [ ] **Step 5: Implement placeholders, build pipeline, and mode selection**

Add:

```swift
static func build(
    snapshot: PowerFlowSnapshot,
    isRefreshing: Bool,
    bundle: Bundle? = nil
) -> PowerFlowDiagramPresentation {
    if isRefreshing, snapshot.timestamp == .distantPast {
        return terminalPresentation(
            mode: .waiting,
            status: .waiting,
            issues: [],
            bundle: bundle
        )
    }

    let normalized = normalize(snapshot: snapshot, bundle: bundle)
    var sources = normalized.sources
    var sinks = normalized.sinks
    var issues = normalized.issues

    if sources.isEmpty, !sinks.isEmpty {
        sources = [
            syntheticNode(
                id: "source:synthetic-unknown-input",
                title: AppLocalization.string(
                    .powerFlowUnknownInput,
                    bundle: bundle
                )
            ),
        ]
        issues.insert(.missingSource)
    } else if sinks.isEmpty, !sources.isEmpty {
        sinks = [
            syntheticNode(
                id: "sink:synthetic-unknown-output",
                title: AppLocalization.string(
                    .powerFlowUnknownOutput,
                    bundle: bundle
                )
            ),
        ]
        issues.insert(.missingSink)
    }

    let sourceSummary = sideSummary(for: sources)
    let sinkSummary = sideSummary(for: sinks)
    addBalanceIssueIfNeeded(
        sourceSummary: sourceSummary,
        sinkSummary: sinkSummary,
        sources: sources,
        sinks: sinks,
        issues: &issues
    )

    let mode = preferredMode(
        sources: sources,
        sinks: sinks,
        idleEndpoints: normalized.idleEndpoints,
        issues: issues
    )
    let status = status(
        mode: mode,
        sources: sources,
        sinks: sinks
    )

    return PowerFlowDiagramPresentation(
        preferredMode: mode,
        sources: sources,
        sinks: sinks,
        idleEndpoints: normalized.idleEndpoints,
        sourceSummary: sourceSummary,
        sinkSummary: sinkSummary,
        issues: issues,
        status: status,
        accessibilityLabel: accessibilityLabel(
            mode: mode,
            status: status,
            sources: sources,
            sinks: sinks,
            sourceSummary: sourceSummary,
            sinkSummary: sinkSummary,
            issues: issues,
            bundle: bundle
        )
    )
}

private static func syntheticNode(
    id: String,
    title: String
) -> PowerFlowDiagramNode {
    PowerFlowDiagramNode(
        id: id,
        kind: .unknown,
        title: title,
        measurement: .unavailable,
        provenance: .absent,
        isSynthetic: true
    )
}

private static func preferredMode(
    sources: [PowerFlowDiagramNode],
    sinks: [PowerFlowDiagramNode],
    idleEndpoints: [PowerFlowDiagramNode],
    issues: Set<PowerFlowDiagramIssue>
) -> PowerFlowDiagramMode {
    if sources.isEmpty, sinks.isEmpty {
        let confirmedIdle = idleEndpoints.contains {
            $0.measurement == .idle
        }
        return confirmedIdle && !issues.contains(.unresolvedIdleMeasurement)
            ? .idle
            : .unavailable
    }

    if sources.count > 2 || sinks.count > 2 {
        return .grouped
    }

    switch (sources.count, sinks.count) {
    case (1, 1): return .expanded(.oneToOne)
    case (1, 2): return .expanded(.oneToMany)
    case (2, 1): return .expanded(.manyToOne)
    case (2, 2): return .expanded(.manyToMany)
    default: return .grouped
    }
}
```

- [ ] **Step 6: Implement reconciliation and status precedence**

```swift
private static func addBalanceIssueIfNeeded(
    sourceSummary: PowerFlowDiagramSideSummary,
    sinkSummary: PowerFlowDiagramSideSummary,
    sources: [PowerFlowDiagramNode],
    sinks: [PowerFlowDiagramNode],
    issues: inout Set<PowerFlowDiagramIssue>
) {
    guard sources.contains(where: { !$0.isSynthetic }),
          sinks.contains(where: { !$0.isSynthetic }),
          let input = sourceSummary.total.exactWatts,
          let output = sinkSummary.total.exactWatts else {
        return
    }

    let tolerance = max(1.0, max(input, output) * 0.05)
    if abs(input - output) > tolerance {
        issues.insert(.unbalancedKnownTotals)
    }
}

private static func status(
    mode: PowerFlowDiagramMode,
    sources: [PowerFlowDiagramNode],
    sinks: [PowerFlowDiagramNode]
) -> PowerFlowDiagramStatus {
    switch mode {
    case .waiting: return .waiting
    case .idle: return .idle
    case .unavailable: return .unavailable
    case .grouped: return .summary
    case .expanded: break
    }

    if sources.contains(where: \.isSynthetic)
        || sinks.contains(where: \.isSynthetic) {
        return .summary
    }

    let realSources = sources.filter { !$0.isSynthetic }
    let realSinks = sinks.filter { !$0.isSynthetic }

    if realSources.contains(where: { $0.kind == .externalPower }),
       realSinks.contains(where: { $0.kind == .battery }) {
        return .charging
    }
    if realSources.count == 1,
       realSources[0].kind == .battery,
       realSinks.count == 1,
       realSinks[0].kind == .mac {
        return .batteryPower
    }
    if realSources.count == 1,
       realSources[0].kind == .externalPower,
       realSinks.count == 1,
       realSinks[0].kind == .mac {
        return .externalPower
    }
    if realSources.count > 1, realSinks.count == 1 {
        return .multipleSources
    }
    return .multipleFlows
}
```

- [ ] **Step 7: Implement accessibility narration**

Use one combined label and full member lists:

```swift
private static func accessibilityLabel(
    mode: PowerFlowDiagramMode,
    status: PowerFlowDiagramStatus,
    sources: [PowerFlowDiagramNode],
    sinks: [PowerFlowDiagramNode],
    sourceSummary: PowerFlowDiagramSideSummary,
    sinkSummary: PowerFlowDiagramSideSummary,
    issues: Set<PowerFlowDiagramIssue>,
    bundle: Bundle?
) -> String {
    let statusText = PowerFlowPresentation.statusText(
        status,
        bundle: bundle
    )

    guard !sources.isEmpty || !sinks.isEmpty else {
        return issues.isEmpty
            ? statusText
            : statusText + AppLocalization.string(
                .powerFlowAccessibilityPartialSuffix,
                bundle: bundle
            )
    }

    let sourceText = accessibilitySideText(
        nodes: sources,
        summary: sourceSummary,
        includesSummary: mode == .grouped,
        bundle: bundle
    )
    let sinkText = accessibilitySideText(
        nodes: sinks,
        summary: sinkSummary,
        includesSummary: mode == .grouped,
        bundle: bundle
    )
    let suffix = issues.isEmpty
        ? ""
        : AppLocalization.string(
            .powerFlowAccessibilityPartialSuffix,
            bundle: bundle
        )

    return AppLocalization.string(
        .powerFlowAccessibilityComponent,
        statusText,
        AppLocalization.string(.powerFlowInput, bundle: bundle),
        sourceText,
        AppLocalization.string(.powerFlowOutput, bundle: bundle),
        sinkText,
        suffix,
        bundle: bundle
    )
}

private static func accessibilitySideText(
    nodes: [PowerFlowDiagramNode],
    summary: PowerFlowDiagramSideSummary,
    includesSummary: Bool,
    bundle: Bundle?
) -> String {
    let members = nodes
        .map { accessibilityNodeText($0, bundle: bundle) }
        .joined(separator: "; ")

    guard includesSummary else { return members }

    return AppLocalization.string(
        .powerFlowAccessibilitySideSummary,
        accessibilityAggregateText(
            summary.total,
            provenance: summary.provenance,
            bundle: bundle
        ),
        members,
        bundle: bundle
    )
}

private static func accessibilityNodeText(
    _ node: PowerFlowDiagramNode,
    bundle: Bundle?
) -> String {
    guard case .exact(let watts) = node.measurement else {
        return AppLocalization.string(
            .powerFlowAccessibilityNodeUnavailable,
            node.title,
            bundle: bundle
        )
    }

    let value = PowerFlowPresentation.powerText(
        .watts(watts),
        locale: AppLocalization.currentLocale(bundle: bundle),
        bundle: bundle
    )
    let key: AppLocalization.Key =
        node.provenance == .derived || node.provenance == .mixed
        ? .powerFlowAccessibilityNodeDerived
        : .powerFlowAccessibilityNodeMeasured

    return AppLocalization.string(
        key,
        node.title,
        value,
        bundle: bundle
    )
}

private static func accessibilityAggregateText(
    _ measurement: PowerFlowDisplayMeasurement,
    provenance: PowerFlowDisplayProvenance,
    bundle: Bundle?
) -> String {
    switch measurement {
    case .exact(let watts):
        let value = PowerFlowPresentation.powerText(
            .watts(watts),
            locale: AppLocalization.currentLocale(bundle: bundle),
            bundle: bundle
        )
        return provenance == .derived || provenance == .mixed
            ? AppLocalization.string(
                .powerFlowAccessibilityAggregateDerived,
                value,
                bundle: bundle
            )
            : value

    case .lowerBound(let knownWatts, let unavailableCount):
        let value = PowerFlowPresentation.powerText(
            .watts(knownWatts),
            locale: AppLocalization.currentLocale(bundle: bundle),
            bundle: bundle
        )
        return AppLocalization.string(
            .powerFlowAccessibilityAggregateLowerBound,
            value,
            Int64(unavailableCount),
            bundle: bundle
        )

    case .unavailable, .idle:
        return AppLocalization.string(
            .powerFlowAccessibilityAggregateUnavailable,
            bundle: bundle
        )
    }
}
```

Add waiting construction:

```swift
private static func terminalPresentation(
    mode: PowerFlowDiagramMode,
    status: PowerFlowDiagramStatus,
    issues: Set<PowerFlowDiagramIssue>,
    bundle: Bundle?
) -> PowerFlowDiagramPresentation {
    let empty = PowerFlowDiagramSideSummary(
        memberCount: 0,
        total: .idle,
        provenance: .absent,
        representatives: []
    )
    return PowerFlowDiagramPresentation(
        preferredMode: mode,
        sources: [],
        sinks: [],
        idleEndpoints: [],
        sourceSummary: empty,
        sinkSummary: empty,
        issues: issues,
        status: status,
        accessibilityLabel: PowerFlowPresentation.statusText(
            status,
            bundle: bundle
        )
    )
}
```

- [ ] **Step 8: Run the complete presentation suite**

```bash
swift test --filter PowerFlowDiagramPresentationTests
```

Expected: every Task 3–4 test passes. Do not weaken the exact accessibility string, tolerance boundary, missing-side, or no-residual assertions.

- [ ] **Step 9: Commit**

```bash
git add \
  Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift \
  Tests/MacActivityAppTests/PowerFlowDiagramPresentationTests.swift
git commit -m "feat: build adaptive power flow presentations"
```

### Task 5: Define pure, testable diagram geometry

**Files:**
- Create: `Sources/MacActivityApp/Views/PowerFlowDiagramLayout.swift`
- Create: `Tests/MacActivityAppTests/PowerFlowDiagramLayoutTests.swift`

**Interfaces:**
- Consumes: `PowerFlowDiagramMode` and topology counts from Task 4.
- Produces:

```swift
PowerFlowDiagramLayout.resolve(
    width: CGFloat,
    preferredMode: PowerFlowDiagramMode,
    sourceCount: Int,
    sinkCount: Int
) -> PowerFlowDiagramLayoutResult
```

The SwiftUI view in Task 6 consumes only this result for placement.

- [ ] **Step 1: Write failing width, height, and region-separation tests**

Create:

```swift
import CoreGraphics
import XCTest
@testable import MacActivityApp

final class PowerFlowDiagramLayoutTests: XCTestCase {
    func testExpandedTopologiesRemainExpandedAt384And320Points() {
        let cases: [(PowerFlowDiagramMode, Int, Int)] = [
            (.expanded(.oneToOne), 1, 1),
            (.expanded(.oneToMany), 1, 2),
            (.expanded(.manyToOne), 2, 1),
            (.expanded(.manyToMany), 2, 2),
        ]

        for width in [CGFloat(384), CGFloat(320)] {
            for (mode, sources, sinks) in cases {
                let layout = resolve(
                    width: width,
                    mode: mode,
                    sources: sources,
                    sinks: sinks
                )
                XCTAssertEqual(layout.effectiveMode, mode)
                XCTAssertEqual(
                    layout.cardFrame.height,
                    PowerFlowDiagramLayout.cardHeight,
                    accuracy: 0.001
                )
                XCTAssertEqual(layout.sourceFrames.count, sources)
                XCTAssertEqual(layout.sinkFrames.count, sinks)
            }
        }
    }

    func testSub320ExpandedModeFallsBackToGrouped() {
        let layout = resolve(
            width: 319,
            mode: .expanded(.manyToMany),
            sources: 2,
            sinks: 2
        )

        XCTAssertEqual(layout.effectiveMode, .grouped)
        XCTAssertNotNil(layout.groupedSourceFrame)
        XCTAssertNotNil(layout.groupedSinkFrame)
    }

    func testExpandedRegionsNeverOverlapAtSupportedWidths() {
        for width in [CGFloat(384), CGFloat(320)] {
            for mode in [
                PowerFlowDiagramMode.expanded(.oneToOne),
                .expanded(.oneToMany),
                .expanded(.manyToOne),
                .expanded(.manyToMany),
            ] {
                let counts = counts(for: mode)
                let layout = resolve(
                    width: width,
                    mode: mode,
                    sources: counts.sources,
                    sinks: counts.sinks
                )

                for source in layout.sourceFrames {
                    XCTAssertFalse(source.intersects(layout.flowFrame))
                }
                for sink in layout.sinkFrames {
                    XCTAssertFalse(sink.intersects(layout.flowFrame))
                }
                for label in layout.flowLabelFrames {
                    XCTAssertTrue(layout.flowFrame.contains(label))
                }
                XCTAssertFalse(
                    layout.sourceFrames.contains {
                        source in layout.sinkFrames.contains {
                            source.intersects($0)
                        }
                    }
                )
            }
        }
    }

    func testTwoLaneFramesKeepApprovedMinimumGap() {
        for width in [CGFloat(384), CGFloat(320)] {
            let layout = resolve(
                width: width,
                mode: .expanded(.manyToMany),
                sources: 2,
                sinks: 2
            )

            XCTAssertGreaterThanOrEqual(
                layout.sourceFrames[1].minY - layout.sourceFrames[0].maxY,
                PowerFlowDiagramLayout.minimumLaneGap
            )
            XCTAssertGreaterThanOrEqual(
                layout.sinkFrames[1].minY - layout.sinkFrames[0].maxY,
                PowerFlowDiagramLayout.minimumLaneGap
            )
        }
    }

    func testGroupedSummaryRegionsDoNotOverlap() {
        for width in [CGFloat(384), CGFloat(320), CGFloat(280)] {
            let layout = resolve(
                width: width,
                mode: .grouped,
                sources: 4,
                sinks: 3
            )
            let source = try! XCTUnwrap(layout.groupedSourceFrame)
            let center = try! XCTUnwrap(layout.groupedCenterFrame)
            let sink = try! XCTUnwrap(layout.groupedSinkFrame)

            XCTAssertFalse(source.intersects(center))
            XCTAssertFalse(center.intersects(sink))
            XCTAssertGreaterThanOrEqual(center.width, 56)
        }
    }

    func testAllModesUseOneStableCardHeight() {
        let modes: [PowerFlowDiagramMode] = [
            .waiting,
            .idle,
            .unavailable,
            .grouped,
            .expanded(.oneToOne),
            .expanded(.oneToMany),
            .expanded(.manyToOne),
            .expanded(.manyToMany),
        ]

        let heights = modes.map {
            resolve(width: 384, mode: $0, sources: 2, sinks: 2)
                .cardFrame.height
        }

        XCTAssertEqual(Set(heights).count, 1)
    }

    private func resolve(
        width: CGFloat,
        mode: PowerFlowDiagramMode,
        sources: Int,
        sinks: Int
    ) -> PowerFlowDiagramLayoutResult {
        PowerFlowDiagramLayout.resolve(
            width: width,
            preferredMode: mode,
            sourceCount: sources,
            sinkCount: sinks
        )
    }

    private func counts(
        for mode: PowerFlowDiagramMode
    ) -> (sources: Int, sinks: Int) {
        switch mode {
        case .expanded(.oneToOne): return (1, 1)
        case .expanded(.oneToMany): return (1, 2)
        case .expanded(.manyToOne): return (2, 1)
        case .expanded(.manyToMany): return (2, 2)
        default: return (0, 0)
        }
    }
}
```

- [ ] **Step 2: Verify the red state**

```bash
swift test --filter PowerFlowDiagramLayoutTests
```

Expected: compilation fails because the layout types do not exist.

- [ ] **Step 3: Create the geometry result**

Create `PowerFlowDiagramLayout.swift`:

```swift
import CoreGraphics

struct PowerFlowDiagramLayoutResult: Equatable {
    var effectiveMode: PowerFlowDiagramMode
    var cardFrame: CGRect
    var statusFrame: CGRect
    var diagramFrame: CGRect
    var sourceFrames: [CGRect]
    var sinkFrames: [CGRect]
    var flowFrame: CGRect
    var flowLabelFrames: [CGRect]
    var busFrame: CGRect?
    var groupedSourceFrame: CGRect?
    var groupedCenterFrame: CGRect?
    var groupedSinkFrame: CGRect?
}
```

- [ ] **Step 4: Add fixed constants and effective-mode selection**

```swift
enum PowerFlowDiagramLayout {
    static let minimumExpandedWidth: CGFloat = 320
    static let cardHeight: CGFloat = 104
    static let outerPadding: CGFloat = 8
    static let statusHeight: CGFloat = 16
    static let statusDiagramSpacing: CGFloat = 6
    static let diagramHeight: CGFloat = 64
    static let nodeToFlowGap: CGFloat = 4
    static let minimumLaneGap: CGFloat = 8
    static let minimumNodeWidth: CGFloat = 40
    static let maximumNodeWidth: CGFloat = 48
    static let minimumFlowLabelWidth: CGFloat = 58
    static let flowLabelHeight: CGFloat = 16

    static func effectiveMode(
        preferredMode: PowerFlowDiagramMode,
        width: CGFloat
    ) -> PowerFlowDiagramMode {
        if width < minimumExpandedWidth,
           case .expanded = preferredMode {
            return .grouped
        }
        return preferredMode
    }
}
```

- [ ] **Step 5: Implement expanded geometry**

Use the following calculations:

```swift
static func resolve(
    width rawWidth: CGFloat,
    preferredMode: PowerFlowDiagramMode,
    sourceCount: Int,
    sinkCount: Int
) -> PowerFlowDiagramLayoutResult {
    let width = max(rawWidth, 1)
    let mode = effectiveMode(
        preferredMode: preferredMode,
        width: width
    )
    let card = CGRect(x: 0, y: 0, width: width, height: cardHeight)
    let status = CGRect(
        x: outerPadding,
        y: outerPadding,
        width: max(0, width - outerPadding * 2),
        height: statusHeight
    )
    let diagram = CGRect(
        x: outerPadding,
        y: status.maxY + statusDiagramSpacing,
        width: max(0, width - outerPadding * 2),
        height: diagramHeight
    )

    if mode == .grouped {
        return groupedResult(
            mode: mode,
            card: card,
            status: status,
            diagram: diagram
        )
    }

    guard case .expanded(let topology) = mode else {
        return emptyResult(
            mode: mode,
            card: card,
            status: status,
            diagram: diagram
        )
    }

    let nodeWidth = min(
        maximumNodeWidth,
        max(
            minimumNodeWidth,
            minimumNodeWidth
                + (width - minimumExpandedWidth)
                / (384 - minimumExpandedWidth)
                * (maximumNodeWidth - minimumNodeWidth)
        )
    )
    let sourceColumn = CGRect(
        x: diagram.minX,
        y: diagram.minY,
        width: nodeWidth,
        height: diagram.height
    )
    let sinkColumn = CGRect(
        x: diagram.maxX - nodeWidth,
        y: diagram.minY,
        width: nodeWidth,
        height: diagram.height
    )
    let flow = CGRect(
        x: sourceColumn.maxX + nodeToFlowGap,
        y: diagram.minY,
        width: max(
            0,
            sinkColumn.minX
                - nodeToFlowGap
                - sourceColumn.maxX
                - nodeToFlowGap
        ),
        height: diagram.height
    )

    let sourceFrames = laneFrames(
        count: sourceCount,
        in: sourceColumn
    )
    let sinkFrames = laneFrames(
        count: sinkCount,
        in: sinkColumn
    )
    let labelCount: Int
    switch topology {
    case .oneToOne: labelCount = 1
    case .oneToMany: labelCount = sinkCount
    case .manyToOne: labelCount = sourceCount + 1
    case .manyToMany: labelCount = sourceCount + sinkCount
    }

    return PowerFlowDiagramLayoutResult(
        effectiveMode: mode,
        cardFrame: card,
        statusFrame: status,
        diagramFrame: diagram,
        sourceFrames: sourceFrames,
        sinkFrames: sinkFrames,
        flowFrame: flow,
        flowLabelFrames: flowLabelFrames(
            count: labelCount,
            topology: topology,
            flowFrame: flow,
            sourceFrames: sourceFrames,
            sinkFrames: sinkFrames
        ),
        busFrame: busFrame(
            topology: topology,
            flowFrame: flow
        ),
        groupedSourceFrame: nil,
        groupedCenterFrame: nil,
        groupedSinkFrame: nil
    )
}
```

Use exact two-lane sizing:

```swift
private static func laneFrames(
    count: Int,
    in column: CGRect
) -> [CGRect] {
    switch count {
    case 0:
        return []
    case 1:
        return [column]
    default:
        let laneHeight = (column.height - minimumLaneGap) / 2
        return [
            CGRect(
                x: column.minX,
                y: column.minY,
                width: column.width,
                height: laneHeight
            ),
            CGRect(
                x: column.minX,
                y: column.maxY - laneHeight,
                width: column.width,
                height: laneHeight
            ),
        ]
    }
}
```

For labels, anchor them to source/sink lane centers and keep them within the flow region:

```swift
private static func flowLabelFrames(
    count: Int,
    topology: PowerFlowDiagramTopology,
    flowFrame: CGRect,
    sourceFrames: [CGRect],
    sinkFrames: [CGRect]
) -> [CGRect] {
    let labelWidth = min(
        max(minimumFlowLabelWidth, flowFrame.width * 0.34),
        max(minimumFlowLabelWidth, flowFrame.width / 2 - 4)
    )

    func frame(centerX: CGFloat, centerY: CGFloat) -> CGRect {
        CGRect(
            x: min(
                max(centerX - labelWidth / 2, flowFrame.minX),
                max(flowFrame.minX, flowFrame.maxX - labelWidth)
            ),
            y: min(
                max(centerY - flowLabelHeight / 2, flowFrame.minY),
                flowFrame.maxY - flowLabelHeight
            ),
            width: labelWidth,
            height: flowLabelHeight
        )
    }

    switch topology {
    case .oneToOne:
        return [
            frame(centerX: flowFrame.midX, centerY: flowFrame.midY),
        ]

    case .oneToMany:
        return sinkFrames.map {
            frame(
                centerX: flowFrame.maxX - labelWidth / 2,
                centerY: $0.midY
            )
        }

    case .manyToOne:
        let branchLabels = sourceFrames.map {
            frame(
                centerX: flowFrame.minX + labelWidth / 2,
                centerY: $0.midY
            )
        }
        return branchLabels + [
            frame(
                centerX: flowFrame.maxX - labelWidth / 2,
                centerY: flowFrame.midY
            ),
        ]

    case .manyToMany:
        let sourceLabels = sourceFrames.map {
            frame(
                centerX: flowFrame.minX + labelWidth / 2,
                centerY: $0.midY
            )
        }
        let sinkLabels = sinkFrames.map {
            frame(
                centerX: flowFrame.maxX - labelWidth / 2,
                centerY: $0.midY
            )
        }
        return sourceLabels + sinkLabels
    }
}
```

- [ ] **Step 6: Implement shared-bus and grouped geometry**

```swift
private static func busFrame(
    topology: PowerFlowDiagramTopology,
    flowFrame: CGRect
) -> CGRect? {
    guard topology == .manyToMany else { return nil }
    return CGRect(
        x: flowFrame.midX - 14,
        y: flowFrame.midY - 12,
        width: 28,
        height: 24
    )
}

private static func groupedResult(
    mode: PowerFlowDiagramMode,
    card: CGRect,
    status: CGRect,
    diagram: CGRect
) -> PowerFlowDiagramLayoutResult {
    let gap: CGFloat = 6
    let sideWidth = min(
        112,
        max(80, (diagram.width - 56 - gap * 2) * 0.36)
    )
    let source = CGRect(
        x: diagram.minX,
        y: diagram.minY,
        width: sideWidth,
        height: diagram.height
    )
    let sink = CGRect(
        x: diagram.maxX - sideWidth,
        y: diagram.minY,
        width: sideWidth,
        height: diagram.height
    )
    let center = CGRect(
        x: source.maxX + gap,
        y: diagram.minY,
        width: max(56, sink.minX - gap - source.maxX - gap),
        height: diagram.height
    )

    return PowerFlowDiagramLayoutResult(
        effectiveMode: mode,
        cardFrame: card,
        statusFrame: status,
        diagramFrame: diagram,
        sourceFrames: [],
        sinkFrames: [],
        flowFrame: center,
        flowLabelFrames: [center.insetBy(dx: 4, dy: 20)],
        busFrame: center.insetBy(dx: 0, dy: 20),
        groupedSourceFrame: source,
        groupedCenterFrame: center,
        groupedSinkFrame: sink
    )
}

private static func emptyResult(
    mode: PowerFlowDiagramMode,
    card: CGRect,
    status: CGRect,
    diagram: CGRect
) -> PowerFlowDiagramLayoutResult {
    PowerFlowDiagramLayoutResult(
        effectiveMode: mode,
        cardFrame: card,
        statusFrame: status,
        diagramFrame: diagram,
        sourceFrames: [],
        sinkFrames: [],
        flowFrame: diagram,
        flowLabelFrames: [],
        busFrame: nil,
        groupedSourceFrame: nil,
        groupedCenterFrame: nil,
        groupedSinkFrame: nil
    )
}
```

If the grouped center width calculation at 280 points violates the non-overlap test, reduce the grouped side floor from `80` to `72`; do not reduce the 56-point center floor or permit overlapping frames.

- [ ] **Step 7: Run layout tests**

```bash
swift test --filter PowerFlowDiagramLayoutTests
```

Expected: every expanded template stays expanded at 320 and 384 points, 319 points falls back to grouped, regions do not overlap, and every mode has one card height.

- [ ] **Step 8: Commit**

```bash
git add \
  Sources/MacActivityApp/Views/PowerFlowDiagramLayout.swift \
  Tests/MacActivityAppTests/PowerFlowDiagramLayoutTests.swift
git commit -m "feat: define power flow diagram geometry"
```

### Task 6: Render the SwiftUI diagram and grouped summary

**Files:**
- Create: `Sources/MacActivityApp/Views/PowerFlowDiagramView.swift`
- Modify: `Tests/MacActivityAppTests/Support/PowerFlowDiagramFixtures.swift`
- Create: `Tests/MacActivityAppTests/PowerFlowDiagramViewTests.swift`

**Interfaces:**
- Consumes: Task 4 presentations and Task 5 layout results.
- Produces `PowerFlowDiagramView(presentation:)`, internal render-plan helpers, node/summary tiles, ribbon shapes, and motion policy for Task 7 integration.

- [ ] **Step 1: Add fixture presentations for every visual mode**

Extend `PowerFlowDiagramFixtures`:

```swift
static func presentation(
    endpoints: [PowerFlowEndpoint],
    isRefreshing: Bool = false
) -> PowerFlowDiagramPresentation {
    PowerFlowDiagramPresentationBuilder.build(
        snapshot: snapshot(endpoints),
        isRefreshing: isRefreshing,
        bundle: englishBundle
    )
}

static var oneToOne: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("source", type: .usbC, direction: .input, measurement: .watts(21.46)),
        endpoint("mac", type: .mac, direction: .output, measurement: .watts(21.46)),
    ])
}

static var oneToMany: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("source", type: .usbC, direction: .input, measurement: .watts(56.8)),
        endpoint("battery", type: .battery, direction: .output, measurement: .watts(30.7)),
        endpoint("mac", type: .mac, direction: .output, measurement: .watts(26.1)),
    ])
}

static var manyToOne: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("source", type: .usbC, direction: .input, measurement: .watts(20)),
        endpoint("battery", type: .battery, direction: .input, measurement: .watts(24)),
        endpoint("mac", type: .mac, direction: .output, measurement: .watts(44)),
    ])
}

static var manyToMany: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("source", type: .usbC, direction: .input, measurement: .watts(45)),
        endpoint("unknown", type: .unknownExternalInterface, direction: .input, measurement: .watts(12)),
        endpoint("battery", type: .battery, direction: .output, measurement: .watts(30)),
        endpoint("mac", type: .mac, direction: .output, measurement: .watts(27)),
    ])
}

static var grouped: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("source", type: .usbC, direction: .input, measurement: .watts(45)),
        endpoint("battery-source", type: .battery, direction: .input, measurement: .watts(12)),
        endpoint("unknown-source", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
        endpoint("battery-sink", type: .battery, direction: .output, measurement: .watts(30)),
        endpoint("mac", type: .mac, direction: .output, measurement: .watts(27)),
    ])
}

static var missingSource: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("mac", type: .mac, direction: .output, measurement: .watts(24)),
    ])
}

static var waiting: PowerFlowDiagramPresentation {
    PowerFlowDiagramPresentationBuilder.build(
        snapshot: .empty,
        isRefreshing: true,
        bundle: englishBundle
    )
}

static var idle: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("battery", type: .battery, direction: .idle, measurement: .watts(0)),
    ])
}

static var unavailable: PowerFlowDiagramPresentation {
    presentation(endpoints: [
        endpoint("battery", type: .battery, direction: .idle, measurement: .unavailable),
    ])
}
```

- [ ] **Step 2: Write failing render-plan and smoke tests**

Create:

```swift
import SwiftUI
import XCTest
@testable import MacActivityApp

@MainActor
final class PowerFlowDiagramViewTests: XCTestCase {
    func testRenderPlanMapsLaneLabelsWithoutInventingEdges() {
        let oneToMany = PowerFlowDiagramRenderPlan(
            presentation: PowerFlowDiagramFixtures.oneToMany,
            width: 384
        )
        let manyToOne = PowerFlowDiagramRenderPlan(
            presentation: PowerFlowDiagramFixtures.manyToOne,
            width: 384
        )
        let manyToMany = PowerFlowDiagramRenderPlan(
            presentation: PowerFlowDiagramFixtures.manyToMany,
            width: 384
        )

        XCTAssertEqual(
            oneToMany.flowLabels.map(\.nodeID),
            PowerFlowDiagramFixtures.oneToMany.sinks.map(\.id)
        )
        XCTAssertEqual(
            manyToOne.flowLabels.map(\.nodeID),
            PowerFlowDiagramFixtures.manyToOne.sources.map(\.id)
                + PowerFlowDiagramFixtures.manyToOne.sinks.map(\.id)
        )
        XCTAssertEqual(
            manyToMany.flowLabels.map(\.nodeID),
            PowerFlowDiagramFixtures.manyToMany.sources.map(\.id)
                + PowerFlowDiagramFixtures.manyToMany.sinks.map(\.id)
        )
        XCTAssertTrue(manyToMany.usesSharedBus)
        XCTAssertFalse(manyToMany.exposesPairwiseEdges)
    }

    func testRenderPlanFallsBackToGroupedBelowWidthFloor() {
        let plan = PowerFlowDiagramRenderPlan(
            presentation: PowerFlowDiagramFixtures.manyToMany,
            width: 319
        )

        XCTAssertEqual(plan.layout.effectiveMode, .grouped)
    }

    func testReduceMotionDisablesGeometryAnimation() {
        XCTAssertNil(
            PowerFlowDiagramMotion.animation(reduceMotion: true)
        )
        XCTAssertNotNil(
            PowerFlowDiagramMotion.animation(reduceMotion: false)
        )
    }

    func testAllDiagramModesRenderAtRealEnergyWidthAndPressureWidth() {
        let presentations = [
            PowerFlowDiagramFixtures.oneToOne,
            .oneToMany,
            .manyToOne,
            .manyToMany,
            .grouped,
            .missingSource,
            .waiting,
            .idle,
            .unavailable,
        ]

        for width in [CGFloat(384), CGFloat(320)] {
            for presentation in presentations {
                let renderer = ImageRenderer(
                    content: PowerFlowDiagramView(
                        presentation: presentation
                    )
                    .frame(width: width)
                )
                renderer.scale = 1
                let image = renderer.nsImage

                XCTAssertNotNil(image)
                XCTAssertEqual(
                    image?.size.height,
                    PowerFlowDiagramLayout.cardHeight,
                    accuracy: 1
                )
            }
        }
    }

    func testLongGermanLabelsStillRenderAt320Points() throws {
        let german = try XCTUnwrap(
            AppLocalization.bundle(forLanguageIdentifier: "de")
        )
        let presentation = PowerFlowDiagramPresentationBuilder.build(
            snapshot: PowerFlowDiagramFixtures.snapshot(
                .init(
                    id: "unknown",
                    type: .unknownExternalInterface,
                    direction: .input,
                    measurement: .unavailable
                ),
                .init(
                    id: "mac",
                    type: .mac,
                    direction: .output,
                    measurement: .watts(21.46)
                )
            ),
            isRefreshing: false,
            bundle: german
        )
        let renderer = ImageRenderer(
            content: PowerFlowDiagramView(presentation: presentation)
                .frame(width: 320)
        )

        XCTAssertNotNil(renderer.nsImage)
        XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
    }
}
```

- [ ] **Step 3: Verify the red state**

```bash
swift test --filter PowerFlowDiagramViewTests
```

Expected: compilation fails because the diagram view, render plan, and motion policy do not exist.

- [ ] **Step 4: Create a render plan that keeps the view semantic-free**

In `PowerFlowDiagramView.swift`:

```swift
import SwiftUI

struct PowerFlowDiagramFlowLabel: Equatable, Identifiable {
    var nodeID: String
    var text: String
    var id: String { nodeID }
}

struct PowerFlowDiagramRenderPlan: Equatable {
    var layout: PowerFlowDiagramLayoutResult
    var flowLabels: [PowerFlowDiagramFlowLabel]
    var usesSharedBus: Bool
    var exposesPairwiseEdges: Bool

    init(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat
    ) {
        layout = PowerFlowDiagramLayout.resolve(
            width: width,
            preferredMode: presentation.preferredMode,
            sourceCount: presentation.sources.count,
            sinkCount: presentation.sinks.count
        )

        switch layout.effectiveMode {
        case .expanded(.oneToOne):
            flowLabels = Self.labels(for: presentation.sinks)

        case .expanded(.oneToMany):
            flowLabels = Self.labels(for: presentation.sinks)

        case .expanded(.manyToOne):
            flowLabels = Self.labels(
                for: presentation.sources + presentation.sinks
            )

        case .expanded(.manyToMany):
            flowLabels = Self.labels(
                for: presentation.sources + presentation.sinks
            )

        case .waiting, .idle, .unavailable, .grouped:
            flowLabels = []
        }

        usesSharedBus =
            layout.effectiveMode == .expanded(.manyToMany)
        exposesPairwiseEdges = false
    }

    private static func labels(
        for nodes: [PowerFlowDiagramNode]
    ) -> [PowerFlowDiagramFlowLabel] {
        nodes.compactMap { node in
            guard let text = PowerFlowPresentation.diagramPowerText(
                node.measurement,
                provenance: node.provenance,
                locale: AppLocalization.currentLocale()
            ) else {
                return nil
            }
            return PowerFlowDiagramFlowLabel(
                nodeID: node.id,
                text: text
            )
        }
    }
}
```

The production view uses the configured app locale. Tests that need a specific language must build localized titles/accessibility through the builder; numeric punctuation is validated separately in `PowerFlowPresentationTests`.

- [ ] **Step 5: Add motion and palette policies**

```swift
enum PowerFlowDiagramMotion {
    static func animation(
        reduceMotion: Bool
    ) -> Animation? {
        reduceMotion
            ? nil
            : .easeInOut(duration: DashboardMotion.valueDuration)
    }
}

enum PowerFlowDiagramPalette {
    static func color(
        for kind: PowerFlowDiagramNodeKind
    ) -> Color {
        switch kind {
        case .externalPower: return .secondary
        case .battery: return .green
        case .mac: return .blue
        case .other: return .indigo
        case .unknown: return .secondary
        }
    }

    static func symbol(
        for kind: PowerFlowDiagramNodeKind
    ) -> String {
        switch kind {
        case .externalPower: return "powerplug.fill"
        case .battery: return "battery.100"
        case .mac: return "laptopcomputer"
        case .other: return "ellipsis"
        case .unknown: return "questionmark"
        }
    }
}
```

Color remains supplementary; node symbols, titles, branch placement, dash treatment, and accessibility carry the semantics.

- [ ] **Step 6: Implement the ribbon primitive**

```swift
private struct PowerFlowRibbonShape: Shape {
    var startCenterY: CGFloat
    var startHeight: CGFloat
    var endCenterY: CGFloat
    var endHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let startTop = startCenterY - startHeight / 2
        let startBottom = startCenterY + startHeight / 2
        let endTop = endCenterY - endHeight / 2
        let endBottom = endCenterY + endHeight / 2
        let controlX = rect.width * 0.52

        var path = Path()
        path.move(to: CGPoint(x: 0, y: startTop))
        path.addCurve(
            to: CGPoint(x: rect.width, y: endTop),
            control1: CGPoint(x: controlX, y: startTop),
            control2: CGPoint(x: rect.width - controlX, y: endTop)
        )
        path.addLine(to: CGPoint(x: rect.width, y: endBottom))
        path.addCurve(
            to: CGPoint(x: 0, y: startBottom),
            control1: CGPoint(x: rect.width - controlX, y: endBottom),
            control2: CGPoint(x: controlX, y: startBottom)
        )
        path.closeSubpath()
        return path
    }
}
```

Add a wrapper that chooses solid or unavailable treatment:

```swift
private struct PowerFlowRibbon: View {
    let startCenterY: CGFloat
    let startHeight: CGFloat
    let endCenterY: CGFloat
    let endHeight: CGFloat
    let kind: PowerFlowDiagramNodeKind
    let measurement: PowerFlowDisplayMeasurement

    var body: some View {
        let shape = PowerFlowRibbonShape(
            startCenterY: startCenterY,
            startHeight: startHeight,
            endCenterY: endCenterY,
            endHeight: endHeight
        )

        switch measurement {
        case .exact:
            shape.fill(
                LinearGradient(
                    colors: [
                        PowerFlowDiagramPalette.color(for: kind)
                            .opacity(0.20),
                        PowerFlowDiagramPalette.color(for: kind)
                            .opacity(0.58),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

        case .unavailable:
            shape.stroke(
                PowerFlowDiagramPalette.color(for: kind)
                    .opacity(0.45),
                style: StrokeStyle(
                    lineWidth: 1,
                    dash: [3, 4]
                )
            )

        case .lowerBound:
            shape.fill(
                PowerFlowDiagramPalette.color(for: kind)
                    .opacity(0.32)
            )

        case .idle:
            EmptyView()
        }
    }
}
```

- [ ] **Step 7: Implement node and grouped-summary tiles**

Node tile:

```swift
private struct PowerFlowDiagramNodeTile: View {
    let node: PowerFlowDiagramNode

    var body: some View {
        VStack(spacing: 3) {
            Image(
                systemName: PowerFlowDiagramPalette.symbol(
                    for: node.kind
                )
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                PowerFlowDiagramPalette.color(for: node.kind)
            )
            .accessibilityHidden(true)

            Text(node.title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .help(node.title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(node.isSynthetic ? 0.035 : 0.065))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(node.isSynthetic ? 0.22 : 0.10),
                    style: StrokeStyle(
                        lineWidth: 0.5,
                        dash: node.isSynthetic ? [3, 3] : []
                    )
                )
        }
    }
}
```

Grouped side:

```swift
private struct PowerFlowDiagramSideSummaryView: View {
    let summary: PowerFlowDiagramSideSummary
    let countKey: AppLocalization.Key

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                AppLocalization.string(
                    countKey,
                    Int64(summary.memberCount)
                )
            )
            .font(.caption2.weight(.semibold))

            ForEach(summary.representatives) { node in
                HStack(spacing: 3) {
                    Image(
                        systemName: PowerFlowDiagramPalette.symbol(
                            for: node.kind
                        )
                    )
                    .accessibilityHidden(true)

                    Text(node.title)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    if let text = PowerFlowPresentation.diagramPowerText(
                        node.measurement,
                        provenance: node.provenance,
                        locale: AppLocalization.currentLocale()
                    ) {
                        Text(text)
                            .monospacedDigit()
                            .layoutPriority(1)
                    }
                }
                .font(.caption2)
            }

            let hidden = summary.memberCount
                - summary.representatives.count
            if hidden > 0 {
                Text(
                    AppLocalization.string(
                        .powerFlowMoreCount,
                        Int64(hidden)
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }
}
```

These internal surfaces use a light fill only; do not call `glassEffect` or `dashboardCardChrome()` on them.

- [ ] **Step 8: Implement the card, status row, expanded content, and empty states**

Use a `GeometryReader` at the root:

```swift
struct PowerFlowDiagramView: View {
    let presentation: PowerFlowDiagramPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let plan = PowerFlowDiagramRenderPlan(
                presentation: presentation,
                width: proxy.size.width
            )

            ZStack(alignment: .topLeading) {
                statusRow
                    .frame(
                        width: plan.layout.statusFrame.width,
                        height: plan.layout.statusFrame.height,
                        alignment: .leading
                    )
                    .position(
                        x: plan.layout.statusFrame.midX,
                        y: plan.layout.statusFrame.midY
                    )

                diagramContent(plan: plan)
            }
            .frame(
                width: plan.layout.cardFrame.width,
                height: plan.layout.cardFrame.height
            )
        }
        .frame(height: PowerFlowDiagramLayout.cardHeight)
        .dashboardCardChrome()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .animation(
            PowerFlowDiagramMotion.animation(
                reduceMotion: reduceMotion
            ),
            value: presentation
        )
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Text(
                PowerFlowPresentation.statusText(
                    presentation.status
                )
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)

            if !presentation.issues.isEmpty {
                Text(
                    AppLocalization.string(
                        .powerFlowPartialData
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let totals = totalsText {
                Text(totals)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }
}
```

`totalsText` must show separate source/sink values when either side is grouped, partial, or unbalanced:

```swift
private var totalsText: String? {
    let shouldShow =
        presentation.preferredMode == .grouped
        || presentation.issues.contains(.unbalancedKnownTotals)
        || {
            if case .lowerBound = presentation.sourceSummary.total { return true }
            if case .lowerBound = presentation.sinkSummary.total { return true }
            return false
        }()

    guard shouldShow,
          let input = PowerFlowPresentation.diagramPowerText(
            presentation.sourceSummary.total,
            provenance: presentation.sourceSummary.provenance,
            locale: AppLocalization.currentLocale()
          ),
          let output = PowerFlowPresentation.diagramPowerText(
            presentation.sinkSummary.total,
            provenance: presentation.sinkSummary.provenance,
            locale: AppLocalization.currentLocale()
          ) else {
        return nil
    }

    return AppLocalization.string(
        .powerFlowTotals,
        input,
        output
    )
}
```

Implement `diagramContent(plan:)` with these branches:

- `.waiting`: centered static `hourglass` symbol plus the localized waiting title; do not use `ProgressView`, symbol effects, opacity pulses, or any repeating animation.
- `.idle`: muted endpoint context and localized idle title, no active ribbon.
- `.unavailable`: question-mark symbol plus localized unavailable title.
- `.grouped`: position two `PowerFlowDiagramSideSummaryView`s in `groupedSourceFrame` and `groupedSinkFrame`; draw one neutral shared bus in `groupedCenterFrame`; show separate aggregate text in the status row.
- `.expanded`: position `PowerFlowDiagramNodeTile`s in source/sink frames, draw ribbons in the flow frame, then position `plan.flowLabels` in `flowLabelFrames`.

For `2→2`, render source ribbons into `busFrame`, render one rounded shared-bus rectangle, then render bus-to-sink ribbons. Do not loop over every source/sink pair.

Every ribbon group must end with:

```swift
.accessibilityHidden(true)
```

Every wattage label uses:

```swift
.font(.caption.monospacedDigit().weight(.semibold))
.lineLimit(1)
.minimumScaleFactor(0.78)
```

Do not apply `fixedSize(horizontal: true, ...)`; labels must remain inside their layout frames.

- [ ] **Step 9: Run view and related layout tests**

```bash
swift test \
  --filter PowerFlowDiagramViewTests

swift test \
  --filter PowerFlowDiagramLayoutTests
```

Expected: all modes render at 384 and 320 points, 319 points uses grouped mode, Reduce Motion has no geometry animation, and the `2→2` render plan exposes one shared bus with no pairwise-edge contract.

- [ ] **Step 10: Commit**

```bash
git add \
  Sources/MacActivityApp/Views/PowerFlowDiagramView.swift \
  Tests/MacActivityAppTests/Support/PowerFlowDiagramFixtures.swift \
  Tests/MacActivityAppTests/PowerFlowDiagramViewTests.swift
git commit -m "feat: render adaptive power flow diagram"
```

### Task 7: Integrate the diagram without changing the sampling lifecycle

**Files:**
- Modify: `Sources/MacActivityApp/Views/PowerFlowView.swift`
- Modify: `Tests/MacActivityAppTests/PowerFlowViewTests.swift`

**Interfaces:**
- Consumes: `PowerFlowDiagramPresentationBuilder.build(...)` and `PowerFlowDiagramView`.
- Produces the production Energy Power Flow component while retaining the existing `.task(id:)` lifecycle exactly once.

- [ ] **Step 1: Update the visible-lifecycle test to the real Energy width**

Replace the existing 420-point rendering assumption with:

```swift
func testRenderedPowerFlowViewAtRealEnergyWidthStartsVisibleLifecycle() async {
    let provider = PowerFlowViewProviderStub(
        snapshot: PowerFlowDiagramFixtures.snapshot(
            .init(
                id: "external",
                type: .usbC,
                direction: .input,
                measurement: .watts(40)
            ),
            .init(
                id: "battery",
                type: .battery,
                direction: .output,
                measurement: .watts(18)
            ),
            .init(
                id: "mac",
                type: .mac,
                direction: .output,
                measurement: .watts(22)
            )
        )
    )
    let model = PowerFlowModel(
        provider: provider,
        observationIntervalNanoseconds: 1,
        nowNanoseconds: { 0 },
        sleep: { _ in throw CancellationError() }
    )
    let snapshotPublished = expectation(
        description: "power-flow snapshot published"
    )
    let observation = model.$snapshot.sink { snapshot in
        if snapshot.outputEndpoints.map(\.type) == [.battery, .mac] {
            snapshotPublished.fulfill()
        }
    }
    defer { observation.cancel() }

    let renderer = ImageRenderer(
        content: PowerFlowView(
            model: model,
            refreshTrigger: 0
        )
        .frame(width: 384)
    )
    renderer.scale = 1

    XCTAssertNotNil(renderer.nsImage)
    await fulfillment(
        of: [snapshotPublished],
        timeout: 1
    )
    XCTAssertEqual(provider.snapshotCount, 1)
    XCTAssertEqual(
        model.snapshot.outputEndpoints.map(\.type),
        [.battery, .mac]
    )
}
```

- [ ] **Step 2: Add a hidden-presentation lifecycle regression test**

```swift
func testHiddenPowerFlowViewDoesNotStartARead() async {
    let provider = PowerFlowViewProviderStub(
        snapshot: PowerFlowDiagramFixtures.snapshot(
            .init(
                id: "source",
                type: .usbC,
                direction: .input,
                measurement: .watts(20)
            ),
            .init(
                id: "mac",
                type: .mac,
                direction: .output,
                measurement: .watts(20)
            )
        )
    )
    let model = PowerFlowModel(
        provider: provider,
        observationIntervalNanoseconds: 1,
        nowNanoseconds: { 0 },
        sleep: { _ in throw CancellationError() }
    )
    let renderer = ImageRenderer(
        content: PowerFlowView(
            model: model,
            refreshTrigger: 0
        )
        .environment(
            \.dashboardPresentationIsPresented,
            false
        )
        .frame(width: 384)
    )

    XCTAssertNotNil(renderer.nsImage)
    await Task.yield()
    await Task.yield()
    XCTAssertEqual(provider.snapshotCount, 0)
}
```

- [ ] **Step 3: Add a presentation-state unit test**

Expose a small target-internal helper and test it:

```swift
func testPowerFlowViewBuildsWaitingThenMeasuredPresentations() {
    let waiting = PowerFlowView.presentation(
        snapshot: .empty,
        isRefreshing: true,
        bundle: PowerFlowDiagramFixtures.englishBundle
    )
    let measured = PowerFlowView.presentation(
        snapshot: PowerFlowDiagramFixtures.snapshot(
            .init(
                id: "battery",
                type: .battery,
                direction: .input,
                measurement: .watts(24)
            ),
            .init(
                id: "mac",
                type: .mac,
                direction: .output,
                measurement: .watts(24)
            )
        ),
        isRefreshing: false,
        bundle: PowerFlowDiagramFixtures.englishBundle
    )

    XCTAssertEqual(waiting.preferredMode, .waiting)
    XCTAssertEqual(
        measured.preferredMode,
        .expanded(.oneToOne)
    )
    XCTAssertEqual(measured.status, .batteryPower)
}
```

- [ ] **Step 4: Run the tests and verify the red state**

```bash
swift test --filter PowerFlowViewTests
```

Expected: the helper does not exist and the current view still renders the two columns.

- [ ] **Step 5: Replace only the rendering body**

Rewrite `PowerFlowView` as:

```swift
import SwiftUI
import MacActivityCore

struct PowerFlowRefreshTaskID: Equatable {
    var presented: Bool = true
    var trigger: Int
}

struct PowerFlowView: View {
    @ObservedObject var model: PowerFlowModel
    @Environment(\.dashboardPresentationIsPresented)
    private var dashboardIsPresented
    let refreshTrigger: Int

    var body: some View {
        PowerFlowDiagramView(
            presentation: Self.presentation(
                snapshot: model.snapshot,
                isRefreshing: model.isRefreshing
            )
        )
        .task(
            id: PowerFlowRefreshTaskID(
                presented: dashboardIsPresented,
                trigger: refreshTrigger
            )
        ) {
            guard dashboardIsPresented else { return }
            await model.refreshWhileVisible()
        }
    }

    static func presentation(
        snapshot: PowerFlowSnapshot,
        isRefreshing: Bool,
        bundle: Bundle? = nil
    ) -> PowerFlowDiagramPresentation {
        PowerFlowDiagramPresentationBuilder.build(
            snapshot: snapshot,
            isRefreshing: isRefreshing,
            bundle: bundle
        )
    }
}
```

Delete `PowerFlowColumn` and `PowerFlowEndpointRow`. Their endpoint-title and watt-format responsibilities now live in `PowerFlowPresentation` and the diagram presentation/view.

Do not add another `.task`, timer, publisher subscription, or `onReceive`.

- [ ] **Step 6: Run view, model, service, and format regressions**

```bash
swift test --filter PowerFlowViewTests
swift test --filter PowerFlowModelTests
swift test --filter PowerFlowServiceTests
swift test --filter PowerFlowPresentationTests
```

Expected: all pass. The provider is called once for the one-shot test, the hidden view performs no read, the model’s cadence/cancellation tests remain unchanged, and adapter capability still never becomes live power.

- [ ] **Step 7: Run the complete Power Flow slice**

```bash
swift test --filter PowerFlow
```

Expected: all Power Flow app/core tests pass, excluding the explicitly opt-in native hardware gate when its environment variable is absent.

- [ ] **Step 8: Commit**

```bash
git add \
  Sources/MacActivityApp/Views/PowerFlowView.swift \
  Tests/MacActivityAppTests/PowerFlowViewTests.swift
git commit -m "feat: integrate power flow diagram"
```

### Task 8: Generate visual evidence and run the complete verification matrix

**Files:**
- Create: `Tests/MacActivityAppTests/PowerFlowDiagramVisualValidationTests.swift`
- Modify: `MacActivity.xcodeproj/project.pbxproj` by running XcodeGen
- Create during execution: `docs/superpowers/verification/2026-09-22-power-flow-diagram.md`

**Interfaces:**
- Consumes: the completed presentation, layout, view, integration, and fixture APIs.
- Produces: deterministic PNG evidence, complete automated/build evidence, and a human-readable verification ledger.

- [ ] **Step 1: Add an opt-in visual evidence test**

Create:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import MacActivityApp

@MainActor
final class PowerFlowDiagramVisualValidationTests: XCTestCase {
    func testExportVisualMatrixWhenExplicitlyRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT"
        ],
        !outputPath.isEmpty else {
            throw XCTSkip(
                "Set MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT to export PNG evidence"
            )
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )

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
            (
                "translucent",
                DashboardPresentationPolicy.translucentAppearance(
                    moduleFillOpacity:
                        DashboardPresentationPolicy
                            .translucentModuleFillOpacity,
                    strokeOpacity:
                        DashboardPresentationPolicy
                            .defaultStrokeOpacity
                )
            ),
        ]
        let colorSchemes: [(String, ColorScheme)] = [
            ("light", .light),
            ("dark", .dark),
        ]

        for (fixtureName, presentation) in fixtures {
            for (appearanceName, appearance) in appearances {
                for (schemeName, scheme) in colorSchemes {
                    let fileName =
                        "\(fixtureName)-\(appearanceName)-\(schemeName)-384.png"
                    try render(
                        presentation: presentation,
                        width: 384,
                        colorScheme: scheme,
                        appearance: appearance,
                        destination: outputURL.appendingPathComponent(
                            fileName
                        )
                    )
                }
            }
        }

        for (fixtureName, presentation) in fixtures.prefix(6) {
            try render(
                presentation: presentation,
                width: 320,
                colorScheme: .light,
                appearance: .standardAppearance,
                destination: outputURL.appendingPathComponent(
                    "\(fixtureName)-standard-light-320.png"
                )
            )
        }
    }

    private func render(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        colorScheme: ColorScheme,
        appearance: DashboardStyleAppearance,
        destination: URL
    ) throws {
        let renderer = ImageRenderer(
            content: PowerFlowDiagramView(
                presentation: presentation
            )
            .environment(\.colorScheme, colorScheme)
            .environment(\.dashboardStyleAppearance, appearance)
            .frame(width: width)
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(
            NSBitmapImageRep(data: tiff)
        )
        let png = try XCTUnwrap(
            representation.representation(
                using: .png,
                properties: [:]
            )
        )
        try png.write(to: destination, options: .atomic)
    }
}
```

The opt-in gate prevents normal CI from writing files.

- [ ] **Step 2: Regenerate the Xcode project**

```bash
xcodegen generate
```

Review the generated project:

```bash
git diff -- MacActivity.xcodeproj/project.pbxproj
```

Expected: only generated references/build-file entries for new source and test files plus deterministic XcodeGen ordering changes. Do not hand-edit the project file.

- [ ] **Step 3: Run focused tests**

```bash
swift test --filter PowerFlowDiagram
swift test --filter PowerFlowViewTests
swift test --filter PowerFlowModelTests
swift test --filter PowerFlowServiceTests
swift test --filter PowerFlowPresentationTests
swift test --filter LocalizationTests
```

Record command, exit code, test count, and elapsed time in the verification ledger.

- [ ] **Step 4: Run the full SwiftPM suite**

```bash
swift test
```

Expected: PASS with no unexpected skips. The native Power Flow gate may skip unless explicitly enabled.

- [ ] **Step 5: Build the actual macOS app**

```bash
xcodebuild \
  -project MacActivity.xcodeproj \
  -scheme MacActivity \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Export the visual matrix**

```bash
rm -rf .build/power-flow-visual-matrix
mkdir -p .build/power-flow-visual-matrix

MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT="$PWD/.build/power-flow-visual-matrix" \
  swift test \
  --filter PowerFlowDiagramVisualValidationTests/testExportVisualMatrixWhenExplicitlyRequested

find .build/power-flow-visual-matrix \
  -type f \
  -name '*.png' \
  | sort
```

Expected: 42 PNG files—36 images for nine fixtures across two dashboard appearances and two color schemes at 384 points, plus six pressure-width images at 320 points.

- [ ] **Step 7: Inspect the PNG matrix**

For every image, record PASS or the exact visual defect against these checks:

- source, flow, and sink regions do not overlap;
- watt labels remain fully readable;
- `2→2` shows a central shared bus, not four pairwise connections;
- unavailable and synthetic lanes remain distinguishable without relying only on color;
- grouped cards show counts, two representatives, and the correct “N more” line;
- waiting, idle, and unavailable keep the same 104-point height;
- transparent/dark combinations retain legible boundaries;
- 320-point images keep branch separation and do not switch to grouped mode unless the semantic mode is already grouped.

Do not approve the matrix from filenames alone; open every PNG.

- [ ] **Step 8: Run the live application matrix**

Launch the built app from Xcode or the build products directory. Validate and record:

| Environment | Required observations |
|---|---|
| Light + standard | Live state readable; no nested-glass look |
| Dark + standard | Labels and unavailable dashes retain contrast |
| Light + translucent | Flow bands remain legible over a varied desktop |
| Dark + translucent | Internal tiles do not become opaque floating cards |
| Increase Contrast | Border/labels strengthen through existing policy |
| Reduce Transparency | Fallback card surface is solid and readable |
| Reduce Motion | Topology changes do not morph; no repeating animation |
| Differentiate Without Color | Icons, labels, ordering, and dash patterns retain meaning |
| Inactive window | Semantic color and text remain readable |

On available hardware, also inspect:

- external power directly supplying the Mac;
- active battery charging;
- battery-only operation;
- rapid connect/disconnect;
- sensor-unavailable behavior if reproducible.

Fixture evidence remains authoritative for topologies that cannot be reproduced on one Mac.

- [ ] **Step 9: Run the opt-in native Power Flow gate when hardware permits**

```bash
MACACTIVITY_POWER_FLOW_NATIVE_VALIDATION=1 \
  swift test \
  --filter PowerFlowNativeValidationTests
```

If the machine lacks an internal battery or cannot enter the required state, record `NOT_RUN` or the explicit `XCTSkip` reason. Do not report it as a pass.

- [ ] **Step 10: Write the verification ledger**

Create `docs/superpowers/verification/2026-09-22-power-flow-diagram.md` after the commands and visual review have produced real evidence.

Start the file with the literal branch name, the literal output of `git rev-parse HEAD`, and the current calendar date. Add an automated-command table containing each command from Steps 3–5, its observed exit code, PASS or FAIL, and the exact final summary line copied from the command output. Record native validation separately as PASS, SKIPPED, or NOT_RUN and copy its observed skip/error reason verbatim.

Add a visual-evidence table with one row for each of these fixtures:

```text
1→1
1→2
2→1
2→2
Grouped
Missing source
Waiting
Idle
Unavailable
```

Give each inspected appearance/width combination an observed PASS or FAIL result. Add an accessibility/live-application section with one row for every condition from Step 8 and a concise observation. Link the evidence directory as `.build/power-flow-visual-matrix`.

The ledger must contain observed data only. Do not enter a passing status for an unrun command, an unopened PNG, or an unavailable hardware state.

- [ ] **Step 11: Commit verification infrastructure and generated project**

```bash
git add \
  Tests/MacActivityAppTests/PowerFlowDiagramVisualValidationTests.swift \
  MacActivity.xcodeproj/project.pbxproj \
  docs/superpowers/verification/2026-09-22-power-flow-diagram.md
git commit -m "test: validate power flow diagram"
```

### Task 9: Perform independent review and close the branch

**Files:**
- Modify only if every required gate passes: `docs/superpowers/specs/2026-09-22-power-flow-diagram-design.md`
- Modify as findings require: files already owned by Tasks 1–8
- Review: the complete `next-version...HEAD` change set

**Interfaces:**
- Consumes: all implementation and verification outputs.
- Produces: a reviewed, reproducible, PR-ready branch with no unresolved Critical or Important findings.

- [ ] **Step 1: Confirm branch scope before review**

```bash
git status --short
git log --oneline --decorate next-version..HEAD
git diff --stat next-version...HEAD
git diff --check next-version...HEAD
```

Expected:

- no untracked implementation files;
- no whitespace errors;
- changes limited to the approved presentation/view/localization/test/project/docs scope;
- no behavioral diff in `PowerFlowModel`, `PowerFlowService`, `SystemPowerFlowReader`, `PowerFlowSMCReader`, or `PowerFlowTypes`.

If any protected file changed, inspect the diff and either revert it or document the genuine correctness defect and obtain user approval before retaining the change.

- [ ] **Step 2: Invoke the independent code-review workflow**

Read and apply:

```bash
cat .agents/skills/pr-readiness-check/SKILL.md
```

Also use the Superpowers `requesting-code-review` skill. Give the reviewer:

- the approved spec path;
- this plan path;
- base `next-version`;
- head `feat/power-flow-diagram`;
- the verification ledger;
- explicit review focus on false topology claims, fabricated wattage, missing-side semantics, 320-point geometry, localization placeholders, accessibility completeness, and sampling regressions.

Require findings grouped as:

- Critical;
- Important;
- Minor.

Do not treat “tests pass” as a substitute for reviewing the shared-bus semantics and uncertainty presentation.

- [ ] **Step 3: Resolve each Critical or Important finding with TDD**

For every accepted finding:

1. add or tighten the smallest failing test in the owning suite;
2. run that test and record the failure;
3. implement the minimum correction;
4. rerun the focused suite;
5. rerun all affected regression suites;
6. commit the correction with a finding-specific message.

Do not bundle unrelated reviewer suggestions into one refactor.

- [ ] **Step 4: Repeat whole-branch verification after review fixes**

```bash
swift test

xcodebuild \
  -project MacActivity.xcodeproj \
  -scheme MacActivity \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

git diff --check next-version...HEAD
```

Re-export and re-inspect the visual matrix if a review fix changes layout, color, typography, motion, localization, or presentation mapping.

- [ ] **Step 5: Update the spec status only with evidence**

When all automated tests pass, the app build succeeds, the required visual/accessibility matrix is complete, and the independent review has zero unresolved Critical or Important findings, change:

```markdown
**Status:** Approved for implementation planning
```

to:

```markdown
**Status:** Implemented and verified
```

Add a final section:

```markdown
## 25. Verification record

Implementation and verification evidence is recorded in
`docs/superpowers/verification/2026-09-22-power-flow-diagram.md`.
```

If any required gate remains unrun, leave the status unchanged and record the exact gap in the verification ledger.

- [ ] **Step 6: Commit closure documentation**

```bash
git add \
  docs/superpowers/specs/2026-09-22-power-flow-diagram-design.md \
  docs/superpowers/verification/2026-09-22-power-flow-diagram.md
git commit -m "docs: close power flow diagram implementation"
```

Skip this commit when the spec status cannot honestly advance and the verification ledger has not changed since Task 8.

- [ ] **Step 7: Produce the final readiness summary**

Run:

```bash
git rev-parse HEAD
git status --short
git log --oneline next-version..HEAD
git diff --stat next-version...HEAD
```

Report:

- exact head commit;
- automated test result;
- Xcode build result;
- native validation result as PASS, SKIPPED, or NOT_RUN with the observed reason;
- visual/accessibility matrix result;
- review finding counts;
- whether the spec status advanced;
- whether the branch is ready to open a PR against `next-version`.

Do not push, publish, or create the PR until the user explicitly authorizes that external action. After authorization, read and apply `.agents/skills/create-pr/SKILL.md` and target `next-version`.

## Appendix A: Exact localization blocks

Append each block to the matching `Localizable.strings` file. These values are part of the implementation contract; placeholder order must remain identical across languages.

### `en.lproj/Localizable.strings`

```strings
"powerFlow.unknownInput" = "Unknown Input";
"powerFlow.unknownOutput" = "Unknown Output";
"powerFlow.sources.count" = "%lld sources";
"powerFlow.outputs.count" = "%lld outputs";
"powerFlow.more.count" = "%lld more";
"powerFlow.partialData" = "Partial Data";
"powerFlow.status.externalPower" = "External Power";
"powerFlow.status.batteryPower" = "Battery Power";
"powerFlow.status.charging" = "Charging";
"powerFlow.status.multipleSources" = "Multiple Sources";
"powerFlow.status.multipleFlows" = "Multiple Power Flows";
"powerFlow.status.summary" = "Power Flow Summary";
"powerFlow.status.waiting" = "Waiting for Power Data";
"powerFlow.status.unavailable" = "Power Data Unavailable";
"powerFlow.status.idle" = "No Active Power Flow";
"powerFlow.totals" = "In %1$@ · Out %2$@";
"powerFlow.accessibility.component" = "%1$@. %2$@: %3$@. %4$@: %5$@.%6$@";
"powerFlow.accessibility.node.measured" = "%1$@, %2$@";
"powerFlow.accessibility.node.derived" = "%1$@, approximately %2$@";
"powerFlow.accessibility.node.unavailable" = "%1$@, power unavailable";
"powerFlow.accessibility.sideSummary" = "Total: %1$@. %2$@";
"powerFlow.accessibility.aggregate.derived" = "approximately %1$@";
"powerFlow.accessibility.aggregate.lowerBound" = "at least %1$@; unavailable readings: %2$lld";
"powerFlow.accessibility.aggregate.unavailable" = "power unavailable";
"powerFlow.accessibility.partialSuffix" = " Partial data.";
```

### `de.lproj/Localizable.strings`

```strings
"powerFlow.unknownInput" = "Unbekannter Eingang";
"powerFlow.unknownOutput" = "Unbekannter Ausgang";
"powerFlow.sources.count" = "%lld Quellen";
"powerFlow.outputs.count" = "%lld Ausgänge";
"powerFlow.more.count" = "%lld weitere";
"powerFlow.partialData" = "Unvollständige Daten";
"powerFlow.status.externalPower" = "Externe Stromversorgung";
"powerFlow.status.batteryPower" = "Batteriebetrieb";
"powerFlow.status.charging" = "Wird geladen";
"powerFlow.status.multipleSources" = "Mehrere Stromquellen";
"powerFlow.status.multipleFlows" = "Mehrere Energieflüsse";
"powerFlow.status.summary" = "Zusammenfassung des Energieflusses";
"powerFlow.status.waiting" = "Warten auf Leistungsdaten";
"powerFlow.status.unavailable" = "Leistungsdaten nicht verfügbar";
"powerFlow.status.idle" = "Kein aktiver Energiefluss";
"powerFlow.totals" = "Ein %1$@ · Aus %2$@";
"powerFlow.accessibility.component" = "%1$@. %2$@: %3$@. %4$@: %5$@.%6$@";
"powerFlow.accessibility.node.measured" = "%1$@, %2$@";
"powerFlow.accessibility.node.derived" = "%1$@, ungefähr %2$@";
"powerFlow.accessibility.node.unavailable" = "%1$@, Leistung nicht verfügbar";
"powerFlow.accessibility.sideSummary" = "Gesamt: %1$@. %2$@";
"powerFlow.accessibility.aggregate.derived" = "ungefähr %1$@";
"powerFlow.accessibility.aggregate.lowerBound" = "mindestens %1$@; nicht verfügbare Messwerte: %2$lld";
"powerFlow.accessibility.aggregate.unavailable" = "Leistung nicht verfügbar";
"powerFlow.accessibility.partialSuffix" = " Unvollständige Daten.";
```

### `fr.lproj/Localizable.strings`

```strings
"powerFlow.unknownInput" = "Entrée inconnue";
"powerFlow.unknownOutput" = "Sortie inconnue";
"powerFlow.sources.count" = "%lld sources";
"powerFlow.outputs.count" = "%lld sorties";
"powerFlow.more.count" = "%lld de plus";
"powerFlow.partialData" = "Données partielles";
"powerFlow.status.externalPower" = "Alimentation externe";
"powerFlow.status.batteryPower" = "Alimentation sur batterie";
"powerFlow.status.charging" = "Recharge";
"powerFlow.status.multipleSources" = "Plusieurs sources";
"powerFlow.status.multipleFlows" = "Plusieurs flux d’énergie";
"powerFlow.status.summary" = "Résumé du flux d’énergie";
"powerFlow.status.waiting" = "En attente des données de puissance";
"powerFlow.status.unavailable" = "Données de puissance indisponibles";
"powerFlow.status.idle" = "Aucun flux d’énergie actif";
"powerFlow.totals" = "Entrée %1$@ · Sortie %2$@";
"powerFlow.accessibility.component" = "%1$@. %2$@ : %3$@. %4$@ : %5$@.%6$@";
"powerFlow.accessibility.node.measured" = "%1$@, %2$@";
"powerFlow.accessibility.node.derived" = "%1$@, environ %2$@";
"powerFlow.accessibility.node.unavailable" = "%1$@, puissance indisponible";
"powerFlow.accessibility.sideSummary" = "Total : %1$@. %2$@";
"powerFlow.accessibility.aggregate.derived" = "environ %1$@";
"powerFlow.accessibility.aggregate.lowerBound" = "au moins %1$@ ; mesures indisponibles : %2$lld";
"powerFlow.accessibility.aggregate.unavailable" = "puissance indisponible";
"powerFlow.accessibility.partialSuffix" = " Données partielles.";
```

### `ja.lproj/Localizable.strings`

```strings
"powerFlow.unknownInput" = "不明な入力";
"powerFlow.unknownOutput" = "不明な出力";
"powerFlow.sources.count" = "%lld個の入力元";
"powerFlow.outputs.count" = "%lld個の出力先";
"powerFlow.more.count" = "ほか%lld件";
"powerFlow.partialData" = "一部のデータ";
"powerFlow.status.externalPower" = "外部電源";
"powerFlow.status.batteryPower" = "バッテリー電源";
"powerFlow.status.charging" = "充電中";
"powerFlow.status.multipleSources" = "複数の電源";
"powerFlow.status.multipleFlows" = "複数の電力フロー";
"powerFlow.status.summary" = "電力フローの概要";
"powerFlow.status.waiting" = "電力データを待機中";
"powerFlow.status.unavailable" = "電力データを利用できません";
"powerFlow.status.idle" = "有効な電力フローはありません";
"powerFlow.totals" = "入力 %1$@・出力 %2$@";
"powerFlow.accessibility.component" = "%1$@。%2$@：%3$@。%4$@：%5$@。%6$@";
"powerFlow.accessibility.node.measured" = "%1$@、%2$@";
"powerFlow.accessibility.node.derived" = "%1$@、約%2$@";
"powerFlow.accessibility.node.unavailable" = "%1$@、電力を利用できません";
"powerFlow.accessibility.sideSummary" = "合計：%1$@。%2$@";
"powerFlow.accessibility.aggregate.derived" = "約%1$@";
"powerFlow.accessibility.aggregate.lowerBound" = "少なくとも%1$@、利用できない測定値：%2$lld件";
"powerFlow.accessibility.aggregate.unavailable" = "電力を利用できません";
"powerFlow.accessibility.partialSuffix" = "一部のデータのみ利用できます。";
```

### `ko.lproj/Localizable.strings`

```strings
"powerFlow.unknownInput" = "알 수 없는 입력";
"powerFlow.unknownOutput" = "알 수 없는 출력";
"powerFlow.sources.count" = "입력 %lld개";
"powerFlow.outputs.count" = "출력 %lld개";
"powerFlow.more.count" = "외 %lld개";
"powerFlow.partialData" = "일부 데이터";
"powerFlow.status.externalPower" = "외부 전원";
"powerFlow.status.batteryPower" = "배터리 전원";
"powerFlow.status.charging" = "충전 중";
"powerFlow.status.multipleSources" = "여러 전원";
"powerFlow.status.multipleFlows" = "여러 전력 흐름";
"powerFlow.status.summary" = "전력 흐름 요약";
"powerFlow.status.waiting" = "전력 데이터 기다리는 중";
"powerFlow.status.unavailable" = "전력 데이터를 사용할 수 없음";
"powerFlow.status.idle" = "활성 전력 흐름 없음";
"powerFlow.totals" = "입력 %1$@ · 출력 %2$@";
"powerFlow.accessibility.component" = "%1$@. %2$@: %3$@. %4$@: %5$@.%6$@";
"powerFlow.accessibility.node.measured" = "%1$@, %2$@";
"powerFlow.accessibility.node.derived" = "%1$@, 약 %2$@";
"powerFlow.accessibility.node.unavailable" = "%1$@, 전력을 사용할 수 없음";
"powerFlow.accessibility.sideSummary" = "합계: %1$@. %2$@";
"powerFlow.accessibility.aggregate.derived" = "약 %1$@";
"powerFlow.accessibility.aggregate.lowerBound" = "최소 %1$@, 사용할 수 없는 측정값: %2$lld개";
"powerFlow.accessibility.aggregate.unavailable" = "전력을 사용할 수 없음";
"powerFlow.accessibility.partialSuffix" = " 일부 데이터만 사용할 수 있습니다.";
```

### `zh-Hans.lproj/Localizable.strings`

```strings
"powerFlow.unknownInput" = "未知输入";
"powerFlow.unknownOutput" = "未知输出";
"powerFlow.sources.count" = "%lld 个输入源";
"powerFlow.outputs.count" = "%lld 个输出";
"powerFlow.more.count" = "另外 %lld 个";
"powerFlow.partialData" = "部分数据";
"powerFlow.status.externalPower" = "外部电源";
"powerFlow.status.batteryPower" = "电池供电";
"powerFlow.status.charging" = "正在充电";
"powerFlow.status.multipleSources" = "多个电源";
"powerFlow.status.multipleFlows" = "多路功率流";
"powerFlow.status.summary" = "功率流摘要";
"powerFlow.status.waiting" = "正在等待功率数据";
"powerFlow.status.unavailable" = "功率数据不可用";
"powerFlow.status.idle" = "没有活动功率流";
"powerFlow.totals" = "输入 %1$@ · 输出 %2$@";
"powerFlow.accessibility.component" = "%1$@。%2$@：%3$@。%4$@：%5$@。%6$@";
"powerFlow.accessibility.node.measured" = "%1$@，%2$@";
"powerFlow.accessibility.node.derived" = "%1$@，约 %2$@";
"powerFlow.accessibility.node.unavailable" = "%1$@，功率不可用";
"powerFlow.accessibility.sideSummary" = "总计：%1$@。%2$@";
"powerFlow.accessibility.aggregate.derived" = "约 %1$@";
"powerFlow.accessibility.aggregate.lowerBound" = "至少 %1$@；不可用读数：%2$lld 个";
"powerFlow.accessibility.aggregate.unavailable" = "功率不可用";
"powerFlow.accessibility.partialSuffix" = "仅有部分数据。";
```

### `zh-Hant.lproj/Localizable.strings`

```strings
"powerFlow.unknownInput" = "未知輸入";
"powerFlow.unknownOutput" = "未知輸出";
"powerFlow.sources.count" = "%lld 個輸入來源";
"powerFlow.outputs.count" = "%lld 個輸出";
"powerFlow.more.count" = "另外 %lld 個";
"powerFlow.partialData" = "部分資料";
"powerFlow.status.externalPower" = "外部電源";
"powerFlow.status.batteryPower" = "電池供電";
"powerFlow.status.charging" = "正在充電";
"powerFlow.status.multipleSources" = "多個電源";
"powerFlow.status.multipleFlows" = "多路功率流";
"powerFlow.status.summary" = "功率流摘要";
"powerFlow.status.waiting" = "正在等待功率資料";
"powerFlow.status.unavailable" = "功率資料無法使用";
"powerFlow.status.idle" = "沒有作用中的功率流";
"powerFlow.totals" = "輸入 %1$@ · 輸出 %2$@";
"powerFlow.accessibility.component" = "%1$@。%2$@：%3$@。%4$@：%5$@。%6$@";
"powerFlow.accessibility.node.measured" = "%1$@，%2$@";
"powerFlow.accessibility.node.derived" = "%1$@，約 %2$@";
"powerFlow.accessibility.node.unavailable" = "%1$@，功率無法使用";
"powerFlow.accessibility.sideSummary" = "總計：%1$@。%2$@";
"powerFlow.accessibility.aggregate.derived" = "約 %1$@";
"powerFlow.accessibility.aggregate.lowerBound" = "至少 %1$@；無法使用的讀數：%2$lld 個";
"powerFlow.accessibility.aggregate.unavailable" = "功率無法使用";
"powerFlow.accessibility.partialSuffix" = "僅有部分資料。";
```

## Plan Self-Review

### Spec coverage

- General `N→M` presentation input, normalization, uncertainty, ordering, aggregate semantics, synthetic missing sides, and no-residual policy: Tasks 2–4.
- Four expanded shared-bus templates, grouped fallback, 320/384-point constraints, and fixed height: Tasks 5–6.
- Existing dashboard appearance policy, no nested glass, and non-proportional bands: Task 6.
- No continuous animation and Reduce Motion behavior: Task 6.
- Sampling lifecycle preservation: Task 7.
- Seven-language localization and placeholder parity: Task 1 and Appendix A.
- Combined accessibility narration, full grouped-member narration, and decorative-path exclusion: Tasks 4 and 6.
- Full automated, Xcode, visual, accessibility, and native evidence: Task 8.
- Independent whole-branch review, branch-scope protection, and honest status advancement: Task 9.

No approved requirement is left without an owning task.

### Placeholder scan

The plan contains no deferred implementation markers. Runtime evidence is deliberately collected in Task 8 rather than guessed in advance.

### Type consistency

The following signatures are authoritative throughout the plan:

```swift
PowerFlowDiagramPresentationBuilder.build(
    snapshot: PowerFlowSnapshot,
    isRefreshing: Bool,
    bundle: Bundle? = nil
) -> PowerFlowDiagramPresentation

PowerFlowDiagramPresentationBuilder.normalize(
    snapshot: PowerFlowSnapshot,
    bundle: Bundle? = nil
) -> PowerFlowDiagramNormalizedContent

PowerFlowDiagramPresentationBuilder.sideSummary(
    for nodes: [PowerFlowDiagramNode]
) -> PowerFlowDiagramSideSummary

PowerFlowDiagramLayout.resolve(
    width: CGFloat,
    preferredMode: PowerFlowDiagramMode,
    sourceCount: Int,
    sinkCount: Int
) -> PowerFlowDiagramLayoutResult
```

Tasks 5–7 consume these names without aliases or renamed variants.

### Review-focus coverage

- Active zero watts: Task 3 `testActiveZeroWattEndpointBecomesIdleAndCreatesNoActiveLane`.
- Duplicate endpoint IDs: Task 3 `testDuplicateCoreIDsReceiveUniqueDeterministicRenderIDs`.
- Reconciliation boundary: Task 4 `testKnownTotalToleranceBoundaryIsAcceptedAndJustBeyondIsFlagged`.
- Missing side with more than two opposite nodes: Task 4 `testMissingSourceWithThreeSinksRemainsGroupedAndNarratesEveryMember`.
- Long localized labels at 320 points: Tasks 5–6 region tests and `testLongGermanLabelsStillRenderAt320Points`.

## Execution Handoff

Plan complete at `docs/superpowers/plans/2026-09-22-power-flow-diagram.md`.

Recommended execution method: **Subagent-driven**. The nine tasks have explicit interfaces but span localization, semantic normalization, geometry, SwiftUI rendering, lifecycle preservation, visual evidence, and independent review; a fresh implementer/reviewer gate per task is worth the extra contexts because a plausible-looking error could misstate real power flow.

Execution must begin in an isolated worktree using `superpowers:using-git-worktrees`, then proceed with `superpowers:subagent-driven-development`. Native execution remains valid when lower cost is more important than per-task independent review.
