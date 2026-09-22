# Power Flow Diagram Design Specification

**Status:** Draft for user review  
**Date:** 2026-09-22  
**Target branch:** `feat/power-flow-diagram`, based on `next-version`  
**Product area:** Energy → Power Flow  
**Selected direction:** General presentation model with controlled UI templates and grouped fallback

## 1. Summary

Replace the current two-column Input/Output lists in the Energy view with a compact, adaptive power-flow diagram.

The presentation model must accept an arbitrary number of source and sink endpoints. The first UI release will render the common topologies directly—`1→1`, `1→2`, `2→1`, and `2→2`—and fall back to a grouped summary whenever either active side contains more than two nodes. The layout may also select grouped rendering below the supported width floor, but all four expanded templates must fit at the supported 320-point minimum.

The diagram must distinguish:

- known endpoint identity with known power;
- known endpoint identity with unavailable power;
- unknown endpoint identity with known power;
- unknown endpoint identity with unavailable power;
- idle endpoints;
- a completely missing source or sink side;
- partially known aggregate totals;
- derived values, including the current Mac allocation.

The diagram must never invent a wattage, use adapter capability as live power, or imply an endpoint-to-endpoint allocation that the data model does not provide.

## 2. Context

The current implementation already separates power collection, service-level calculation, observable model state, and view rendering:

```text
SystemPowerFlowReader / PowerFlowSMCReader
                    ↓
             PowerFlowService
                    ↓
             PowerFlowSnapshot
                    ↓
              PowerFlowModel
                    ↓
              PowerFlowView
```

`PowerFlowSnapshot` contains an arbitrary endpoint array. Each endpoint has an identifier, endpoint type, direction, and measurement. The current view reduces this into two independent columns by filtering `inputEndpoints` and `outputEndpoints`.

The service currently supports several real relationships, including external power supplying the Mac, external power charging the battery while supplying the Mac, battery-only operation, and external power plus battery discharge supplying the Mac together.

The raw snapshot does **not** express edge-level allocation between every source and every sink. Therefore, a generalized `N→M` UI must use a shared-bus model rather than drawing a complete bipartite graph or claiming that one specific source powers one specific sink.

## 3. Goals

1. Present the direction of power in a form that is understandable at a glance.
2. Support an arbitrary source and sink count in the presentation model.
3. Render `1→1`, `1→2`, `2→1`, and `2→2` clearly at the Energy content width of approximately 384 points.
4. Degrade deterministically into a grouped summary for larger topologies.
5. Treat unknown identity, unavailable measurement, idle state, and missing counterpart as separate concepts.
6. Preserve the current three-second sampling lifecycle and cancellation behavior.
7. Reuse the dashboard’s existing standard and translucent appearance system.
8. Preserve macOS 13 as the deployment target and add no third-party UI dependency.
9. Provide deterministic, unit-testable presentation mapping independent of SwiftUI rendering.
10. Avoid continuous animation or decorative effects that consume energy in an energy-monitoring interface.

## 4. Non-goals

The first implementation will not:

- render more than two individual sources or two individual sinks at once;
- draw a precise edge for every source/sink pair;
- scale every flow-band width proportionally to wattage;
- infer a numerical residual source or sink from an input/output mismatch;
- change the sampling interval or add a second timer;
- replace the existing SMC, IOKit, or service calculation logic;
- expose an interactive topology editor or an expandable full graph;
- add a new preference controlling this visualization;
- raise the minimum macOS version;
- use adapter-rated wattage as a live measurement.

## 5. Approved product decisions

### 5.1 Controlled UI over fully expanded graphs

The data-facing presentation layer is general, but the UI uses a small set of purpose-built templates. This preserves readability in the menu-bar dashboard and avoids a dense graph-layout problem.

### 5.2 Shared-bus semantics

All active source nodes merge into a conceptual system power bus. All active sink nodes branch from that bus.

This model communicates the facts available from the snapshot:

- these endpoints contribute power;
- these endpoints consume or receive power;
- these are their measured or unavailable values.

It does not claim a direct source-to-sink allocation that the current data model cannot prove.

### 5.3 Static geometry with short transitions

Flow bands use stable geometry and non-proportional lane widths. Wattage is communicated by text, not by band thickness. State changes may cross-fade or morph briefly, but there is no persistent flowing shimmer, particle effect, or repeating animation.

### 5.4 Grouping instead of overflow

If either active side contains more than two nodes, the whole component switches to grouped-summary mode. It does not attempt a mixed, partially expanded graph.

### 5.5 Unknown is explicit, not treated as failure

An unknown endpoint remains visible when it materially participates in the flow. Unknown identity does not imply that its wattage is unavailable, and unavailable wattage does not imply that its identity is unknown.

## 6. Terminology

- **Source:** An endpoint with direction `.input`.
- **Sink:** An endpoint with direction `.output`.
- **Idle endpoint:** An endpoint with direction `.idle`. It does not participate in the active topology.
- **Unknown identity:** The endpoint exists and its side is known, but the hardware or logical identity cannot be classified.
- **Unavailable measurement:** The endpoint exists, but a reliable wattage is not available.
- **Missing counterpart:** One active side exists while the other side has no active endpoint at all.
- **Synthetic placeholder:** A presentation-only Unknown Input or Unknown Output inserted for a missing counterpart. It never carries an inferred wattage.
- **Grouped side summary:** A presentation-only summary card for several endpoints. It is not a real hardware endpoint.
- **Derived value:** A value calculated from other measurements. The current Mac power allocation is derived.
- **Partial aggregate:** The sum of known member values when one or more members have unavailable measurements. It is displayed as a lower bound.

## 7. Architecture

The feature is split into three responsibilities:

```text
PowerFlowSnapshot + PowerFlowModel.isRefreshing
                    ↓
       PowerFlowDiagramPresentationBuilder
                    ↓
        PowerFlowDiagramPresentation
                    ↓
             PowerFlowDiagramView
```

### 7.1 Snapshot and model

`PowerFlowModel` remains responsible for refreshing snapshots while the dashboard is visible. Its sampling cadence, cancellation behavior, stale-run protection, and reset-on-new-run behavior remain unchanged.

### 7.2 Presentation builder

A synchronous presentation builder converts a snapshot plus refresh state into a render-ready model. It owns:

- endpoint normalization;
- source/sink/idle classification;
- synthetic missing-counterpart placeholders;
- deterministic ordering;
- topology selection;
- grouped-summary selection;
- aggregate measurement semantics;
- data-quality issues;
- localized labels and accessibility narration.

The builder accepts an optional localization bundle so tests can use the existing language-specific bundle pattern without relying on process-global UI state:

```swift
PowerFlowDiagramPresentationBuilder.build(
    snapshot: PowerFlowSnapshot,
    isRefreshing: Bool,
    bundle: Bundle? = nil
) -> PowerFlowDiagramPresentation
```

It must not import AppKit or perform asynchronous work.

### 7.3 Diagram view

The SwiftUI view renders the supplied presentation. It owns:

- node tiles;
- flow bands and shared-bus geometry;
- grouped side-summary cards;
- labels and aggregate summaries;
- standard/translucent appearance adaptation;
- short state transitions;
- accessibility attachment.

It must not infer topology or calculate business semantics directly from `PowerFlowSnapshot`.

## 8. Presentation model

The implementation should provide types equivalent to the following interfaces. Exact access control may follow existing project conventions.

```swift
struct PowerFlowDiagramPresentation: Equatable {
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

enum PowerFlowDiagramMode: Equatable {
    case waiting
    case idle
    case expanded(PowerFlowDiagramTopology)
    case grouped
    case unavailable
}

enum PowerFlowDiagramTopology: Equatable {
    case oneToOne
    case oneToMany
    case manyToOne
    case manyToMany
}

struct PowerFlowDiagramNode: Identifiable, Equatable {
    var id: String
    var kind: PowerFlowDiagramNodeKind
    var title: String
    var measurement: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var isSynthetic: Bool
}

struct PowerFlowDiagramSideSummary: Equatable {
    var memberCount: Int
    var total: PowerFlowDisplayMeasurement
    var provenance: PowerFlowDisplayProvenance
    var representatives: [PowerFlowDiagramNode]
}

enum PowerFlowDiagramNodeKind: Equatable {
    case externalPower
    case battery
    case mac
    case other
    case unknown
}

enum PowerFlowDisplayMeasurement: Equatable {
    case exact(Double)
    case lowerBound(knownWatts: Double, unavailableCount: Int)
    case unavailable
    case idle
}

enum PowerFlowDisplayProvenance: Equatable {
    case measured
    case derived
    case mixed
    case absent
}

enum PowerFlowDiagramStatus: Equatable {
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
```

`PowerFlowDiagramIssue` must be finite and explicit. Initial cases are:

- `missingSource`
- `missingSink`
- `missingMeasurements`
- `unbalancedKnownTotals`
- `unresolvedIdleMeasurement`

Unknown identity is not itself an issue when direction and power are known. Issues produce a localized Partial Data indication without replacing the primary operational status unless the mode itself is unavailable.

## 9. Normalization rules

The builder applies these rules in order.

### 9.1 Sanitize measurements

A `.watts` value is displayable only when it is finite and non-negative. Invalid defensive inputs become `.unavailable`. A zero-watt endpoint is treated as idle for presentation even if upstream data incorrectly marks it active.

### 9.2 Classify direction

- `.input` becomes a source.
- `.output` becomes a sink.
- `.idle` is recorded separately and does not count toward topology selection.

Any active, non-synthetic source or sink with unavailable measurement adds `missingMeasurements`.

An idle endpoint with unavailable measurement adds `unresolvedIdleMeasurement`, because the UI must not claim that it is a confirmed zero-flow state.

### 9.3 Map endpoint kind

Current endpoint types map as follows:

| Core endpoint type | Diagram node kind |
|---|---|
| `.usbC`, `.magSafe` | `.externalPower` |
| `.battery` | `.battery` |
| `.mac` | `.mac` |
| `.unknownExternalInterface` | `.unknown` |

Presentation titles retain the more specific localized USB-C and MagSafe labels even though both share the external-power visual kind.

The `.other` diagram kind is reserved for future identified endpoint types that are neither external power, battery, nor Mac. It is not produced by the current core enum.

### 9.4 Mark current value provenance

- Current external and battery wattages are treated as measured.
- Current Mac wattage is treated as derived because `PowerFlowService` calculates it from input and battery contribution.
- A side summary is `.mixed` if its real members do not all share the same provenance.
- Synthetic placeholders use `.absent`.

This mapping is isolated in the builder so a future core-level provenance field can replace it without changing the view contract.

### 9.5 Add a missing-counterpart placeholder

If active sinks exist and active sources are empty, insert one synthetic source:

- title: localized “Unknown Input”;
- kind: `.unknown`;
- measurement: `.unavailable`;
- provenance: `.absent`;
- issue: `missingSource`.

If active sources exist and active sinks are empty, insert one synthetic sink using the equivalent “Unknown Output” semantics and add `missingSink`.

A synthetic placeholder communicates a missing side only. It is excluded from aggregate wattage and never receives an inferred value. It still counts as one visible node for topology selection.

If neither side has an active endpoint, do not insert placeholders. Use waiting, idle, or unavailable mode according to the rules below.

## 10. Measurement and aggregation rules

### 10.1 Individual values

- Exact measured value: existing localized watts/milliwatts formatter.
- Exact derived value: prefix the visual value with `≈`.
- Unavailable value: em dash in the compact diagram; the full localized explanation remains available through accessibility and the Energy information text.
- Idle value: no active lane and no watt label.

### 10.2 Side aggregates

For the real, non-synthetic active members on one side:

1. If every member has an exact value, return `.exact(sum)`.
2. If at least one member has an exact value and at least one is unavailable, return `.lowerBound(knownWatts: sum, unavailableCount: count)`.
3. If no member has an exact value, return `.unavailable`.
4. If the side has no real active member, return `.idle` when it is genuinely empty, or `.unavailable` when represented only by a synthetic placeholder.

A lower bound displays `≥` before the known sum. If the aggregate also contains derived members, `≥` takes visual precedence; the mixed/derived nature is stated in accessibility text rather than producing an ambiguous `≈≥` prefix.

Side-summary representatives are the first two members after deterministic sorting. The member count includes synthetic placeholders for visible topology narration, while aggregate wattage excludes them.

### 10.3 No numerical residual inference

The builder never creates an unknown source or sink with a calculated residual value. Measurement latency, sensor availability, and derived Mac allocation can cause differences that are not evidence of a real hidden endpoint.

### 10.4 Known-total reconciliation

When both side aggregates are exact and each side contains at least one real member, compare them only to determine display quality. They are considered reconciled when their absolute difference is no greater than:

```text
max(1.0 W, 5% of the larger total)
```

Outside that tolerance, add `unbalancedKnownTotals` and show input and output totals separately. Do not alter endpoint values and do not create a residual node.

## 11. Deterministic ordering

Stable ordering prevents nodes from swapping positions when values fluctuate.

### 11.1 Source order

1. external power;
2. battery;
3. other identified endpoint;
4. unknown;
5. synthetic placeholder after a real node of the same kind.

### 11.2 Sink order

1. battery;
2. Mac;
3. other identified endpoint;
4. unknown;
5. synthetic placeholder after a real node of the same kind.

Within the same kind:

1. real nodes before synthetic placeholders;
2. exact values before unavailable values;
3. descending wattage for exact values;
4. stable endpoint ID as the final tie-breaker.

## 12. Status selection

Status communicates the operating pattern; issues communicate data quality.

Apply the following precedence:

1. waiting mode → `.waiting`;
2. idle mode → `.idle`;
3. unavailable mode → `.unavailable`;
4. grouped mode → `.summary`;
5. any synthetic missing counterpart → `.summary` plus Partial Data;
6. external power source with battery sink → `.charging`;
7. battery as the only real source and Mac as the sink → `.batteryPower`;
8. one external-power source and one Mac sink → `.externalPower`;
9. multiple real sources and one sink → `.multipleSources`;
10. all other expanded multi-side topologies → `.multipleFlows`.

This keeps “Partial Data” separate from useful operational context while preventing a missing-side diagram from claiming a normal complete state.

## 13. Topology and mode selection

Mode selection uses active nodes after normalization and placeholder insertion.

### 13.1 Waiting

Use `.waiting` when `PowerFlowModel.isRefreshing` is true and the snapshot is the reset sentinel (`timestamp == .distantPast`). The component keeps its normal height and does not show values from a previous visible run.

### 13.2 Idle

Use `.idle` when there are no active sources or sinks, at least one endpoint is confirmed idle with an exact zero measurement, and no unresolved idle measurement prevents that conclusion.

### 13.3 Unavailable

Use `.unavailable` when there are no active sources or sinks and the available endpoint information cannot establish a reliable idle state.

### 13.4 Expanded templates

Use `.expanded` only when both sides contain one or two visible nodes after placeholder insertion:

| Sources | Sinks | Topology |
|---:|---:|---|
| 1 | 1 | `.oneToOne` |
| 1 | 2 | `.oneToMany` |
| 2 | 1 | `.manyToOne` |
| 2 | 2 | `.manyToMany` |

Unknown nodes and unavailable measurements count as nodes. They do not force grouping by themselves.

### 13.5 Grouped summary

Use `.grouped` when either side contains more than two active nodes.

The grouped view contains:

- a source summary card;
- a central aggregate area;
- a sink summary card.

Each side card shows:

- localized source/sink count;
- up to two deterministic representative members;
- an “N more” line when additional members remain;
- an exact, lower-bound, or unavailable aggregate as defined above.

The full ordered member list is included in the accessibility label and may be attached as non-essential hover help. There is no expansion control in the first release.

### 13.6 Width-driven render fallback

`preferredMode` is semantic and does not depend on geometry. `PowerFlowDiagramLayout` may select grouped rendering when the available width is below 320 points. Within the supported 320–384 point range, every expanded template must remain expanded and pass non-overlap tests.

## 14. Visual design

### 14.1 Overall surface

The component is one dashboard card using the existing `.dashboardCardChrome()` treatment. Node tiles and grouped summaries are internal layers on that surface, not independent glass cards.

The implementation must respect `DashboardStyleAppearance`:

- standard mode uses existing system foregrounds and per-card chrome;
- translucent mode uses the root glass and the established module fill/stroke values;
- Reduce Transparency falls back through the existing presentation policy;
- Increase Contrast uses the existing stronger stroke values.

No new bespoke blur or opaque background system is introduced.

### 14.2 Size targets

Initial design targets at the real Energy content width:

- available width: approximately 384 pt;
- supported test floor: 320 pt;
- outer padding: 8 pt;
- status row: 14–16 pt;
- gap between status and diagram: 6 pt;
- diagram area: 64 pt;
- expanded node tile width: 40–48 pt;
- source/sink-to-band gap: 4 pt;
- two-lane height: approximately 24 pt per lane with an 8 pt gap;
- total card height: stable within approximately 96–108 pt across all modes.

The implementation plan may adjust individual constants after rendering, but it must preserve the fixed-height intent and supported width range.

### 14.3 Flow geometry

- `1→1`: one continuous band.
- `1→2`: one trunk splitting into two sink lanes.
- `2→1`: two source lanes merging into one trunk.
- `2→2`: two source lanes merge into a shared bus, then split into two sink lanes.

The `2→2` template must not draw four source-to-sink edges. The center bus explicitly avoids claiming unsupported allocation.

### 14.4 Lane labels

- `1→1`: the main band carries the sink value; a derived Mac value uses `≈`.
- `1→2`: each output branch carries its sink value; the status row may show total input.
- `2→1`: each input branch carries its source value; the trunk carries the sink value.
- `2→2`: source and sink branches carry their node values; aggregate input/output information appears in the status row rather than overcrowding the bus.
- grouped: the center area carries the aggregate summary.

### 14.5 Visual states

- **Known power:** solid, low-contrast gradient band.
- **Unknown identity with known power:** same active band treatment; question-mark node icon and explicit title communicate identity uncertainty.
- **Unavailable power:** outlined or softly dashed band and em-dash value.
- **Synthetic missing counterpart:** question-mark node with unavailable treatment and missing-side wording; it must look different from an identified endpoint whose sensor temporarily failed.
- **Idle:** muted endpoint context without an active band.
- **Grouped:** compact side-summary cards connected by a simplified neutral bus.

Color is supplementary. Icons, ordering, labels, lane presence, and accessibility text must communicate the same state without color.

### 14.6 Status row

The status row provides a localized high-level state, such as:

- External Power
- Battery Power
- Charging
- Multiple Sources
- Multiple Power Flows
- Power Flow Summary
- Waiting for Power Data
- Power Data Unavailable

When `issues` is non-empty, it also shows a localized Partial Data indicator.

When useful, the trailing side shows compact separate totals, for example `In 57 W · Out ≥27 W`. It must not collapse mismatched totals into one number.

## 15. Responsive behavior

The component is optimized for the current 384 pt content width and must remain usable down to 320 pt in tests.

Within the supported range, adaptation occurs in this order:

1. reduce internal horizontal spacing;
2. reduce expanded node tile width within the approved range;
3. reduce non-critical title width and use localized hover help;
4. preserve critical watt-value width and branch separation.

Critical watt values must not be truncated. Node titles may truncate visually only when their full localized value remains in accessibility text and hover help.

Widths below 320 pt may use grouped rendering. The view does not switch to a vertically stacked mobile layout because this is a macOS popover and fixed-height stability is a primary requirement.

## 16. Motion

- No repeating animation.
- Value changes use the project’s existing short value animation where appropriate.
- Topology changes may cross-fade and use a short geometry transition between stable node IDs.
- Reduce Motion disables geometry morphing and uses an immediate update or simple opacity transition.
- The sampling cadence does not drive a continuous animation timeline.

## 17. Accessibility

Decorative flow paths are hidden from accessibility.

The component exposes one primary combined accessibility element that narrates:

1. status;
2. ordered sources and measurements;
3. ordered sinks and measurements;
4. whether values are measured, derived, lower bounds, or unavailable;
5. any partial-data issue.

Example meaning, localized in implementation:

```text
Charging. Input: USB-C, 56.8 watts. Outputs: Battery, 30.7 watts; Mac, approximately 26.1 watts.
```

For grouped mode, the label includes all grouped members, not only the two visible representatives.

The design must remain understandable with Differentiate Without Color, Increase Contrast, Reduce Transparency, and Reduce Motion enabled.

## 18. Localization

Add localized strings for:

- Unknown Input
- Unknown Output
- Sources / Outputs counts
- N more
- Partial Data
- Power Flow Summary
- Multiple Sources
- Multiple Power Flows
- Waiting for Power Data
- Power Data Unavailable
- lower-bound and derived accessibility phrases
- grouped accessibility narration

Existing USB-C, MagSafe, Battery, Mac, Input, Output, and unavailable-power strings should be reused where their meaning remains correct.

All supported localization bundles must receive the new keys. Localization tests must prevent missing entries.

## 19. Integration and file boundaries

### 19.1 New files

- `Sources/MacActivityApp/Models/PowerFlowDiagramPresentation.swift`
  - presentation types;
  - synchronous builder;
  - sorting, summaries, aggregation, issue detection, and localized accessibility narration.

- `Sources/MacActivityApp/Views/PowerFlowDiagramView.swift`
  - diagram composition;
  - node and grouped-summary tiles;
  - shared-bus shapes;
  - appearance and motion adaptation.

- `Sources/MacActivityApp/Views/PowerFlowDiagramLayout.swift`
  - pure geometry constants and frame calculations;
  - sub-320-point grouped fallback decision;
  - testable non-overlap calculations.

### 19.2 Modified files

- `Sources/MacActivityApp/Views/PowerFlowView.swift`
  - retain the current task lifecycle;
  - build a presentation from model state;
  - render `PowerFlowDiagramView`;
  - remove the current paired list columns after the new diagram is covered by tests.

- `Sources/MacActivityApp/Models/PowerFlowPresentation.swift`
  - reuse current watt formatting;
  - add formatting helpers for derived and lower-bound display values if appropriate.

- `Sources/MacActivityApp/Localization/AppLocalization.swift`
  - add new localization keys and helper phrases.

- `Sources/MacActivityApp/Resources/*/Localizable.strings`
  - add translations for every supported language.

### 19.3 Unchanged responsibilities

The feature must not move sampling or service logic into the view. The following files are expected to remain behaviorally unchanged unless implementation exposes a genuine correctness defect:

- `Sources/MacActivityApp/Models/PowerFlowModel.swift`
- `Sources/MacActivityCore/Metrics/Providers/PowerFlowService.swift`
- `Sources/MacActivityCore/Metrics/Providers/SystemPowerFlowReader.swift`
- `Sources/MacActivityCore/Metrics/Providers/PowerFlowSMCReader.swift`
- `Sources/MacActivityCore/Metrics/Providers/PowerFlowTypes.swift`

## 20. Testing strategy

### 20.1 Presentation tests

Create `Tests/MacActivityAppTests/PowerFlowDiagramPresentationTests.swift` covering at least:

1. external power → Mac (`1→1`);
2. battery → Mac (`1→1`);
3. external power → battery + Mac (`1→2`);
4. external power + battery → Mac (`2→1`);
5. external power + unknown source → battery + Mac (`2→2`);
6. three sources triggering grouped mode;
7. three sinks triggering grouped mode;
8. unknown identity with exact wattage remaining active;
9. known identity with unavailable wattage using unavailable treatment;
10. no source plus active sink inserting Unknown Input without inferred watts;
11. active source plus no sink inserting Unknown Output without inferred watts;
12. exact plus unavailable grouped members producing a lower bound;
13. all unavailable grouped members producing unavailable aggregate;
14. idle endpoints not counting toward topology;
15. idle endpoint with unavailable measurement adding an issue;
16. input/output mismatch outside tolerance adding `unbalancedKnownTotals` without a residual node;
17. deterministic ordering independent of endpoint input order;
18. invalid defensive watt values becoming unavailable;
19. current Mac values being marked derived;
20. waiting, idle, and unavailable mode selection;
21. status precedence with synthetic placeholders and partial-data issues;
22. side-summary representatives and counts.

### 20.2 Layout tests

Create `Tests/MacActivityAppTests/PowerFlowDiagramLayoutTests.swift` covering:

- 384 pt layouts for all four expanded templates;
- 320 pt pressure layouts;
- no overlap between source tiles, flow area, labels, and sink tiles;
- stable component height across expanded modes;
- grouped-summary geometry;
- minimum branch spacing and label width;
- sub-320-point grouped fallback.

### 20.3 View tests

Extend or replace the current `PowerFlowViewTests` to verify:

- rendering each mode with `ImageRenderer`;
- starting the existing visible refresh lifecycle;
- preserving the real Energy content width rather than testing only 420 pt;
- decorative shapes being accessibility-hidden;
- combined accessibility narration being present;
- Reduce Motion producing the non-morphing path.

These are rendering smoke tests, not pixel-perfect visual approval.

### 20.4 Regression tests

Keep all existing tests for:

- power-flow service calculations;
- adapter capability not becoming live wattage;
- power formatting;
- immediate first sample and three-second cadence;
- cancellation;
- stale task suppression;
- reset before a new visible run;
- native validation gate.

### 20.5 Manual visual matrix

Review the running application in:

- light and dark appearances;
- standard and translucent dashboard styles;
- focused and inactive states;
- Increase Contrast;
- Reduce Transparency;
- Reduce Motion;
- long localized strings;
- `1→1`, `1→2`, `2→1`, `2→2`, grouped, missing source, missing sink, waiting, idle, and unavailable fixtures.

Native hardware checks should include external power, active charging, battery-only operation, and rapid connect/disconnect where reproducible. A native test on one Mac does not replace fixture coverage of topologies that hardware cannot easily reproduce.

## 21. Acceptance criteria

The feature is ready for branch review when all of the following are true:

1. The presentation builder accepts arbitrary source and sink counts.
2. `1→1`, `1→2`, `2→1`, and `2→2` render as dedicated templates.
3. More than two nodes on either active side produces grouped-summary mode.
4. The `2→2` display uses shared-bus semantics and does not claim edge-level allocation.
5. Unknown identity with known power is displayed as an active node.
6. Known identity with unavailable power remains identifiable and shows unavailable measurement.
7. A missing active side produces a non-numeric Unknown Input or Unknown Output placeholder.
8. Partial aggregates use a lower-bound presentation.
9. No wattage is inferred from balance, adapter rating, or UI needs.
10. Input/output mismatches remain visible as separate totals and a partial-data state.
11. The card remains stable and legible at 384 pt, and does not overlap at 320 pt.
12. The implementation uses existing dashboard appearance policy and does not add nested custom glass.
13. There is no continuous animation.
14. The combined accessibility label fully describes grouped and unknown states.
15. Existing service and lifecycle behavior remains covered and passing.
16. All supported localization bundles contain the new keys.
17. Full automated tests, Xcode application build, and the manual visual matrix are completed before merge into `next-version`.

## 22. Risks and mitigations

### Edge mapping is unavailable

**Risk:** A conventional graph could imply a false source-to-sink relationship.  
**Mitigation:** Use a central shared bus and avoid pairwise edges.

### Sensor data can be incomplete or temporarily inconsistent

**Risk:** A visually complete graph could overstate certainty.  
**Mitigation:** Use unavailable, lower-bound, partial-data, and separate-total states; never fabricate a residual.

### Grouping hides detail

**Risk:** Users may not see every endpoint in a complex topology.  
**Mitigation:** Show count, representative members, full accessibility narration, and optional hover help. The compact dashboard prioritizes comprehension over exhaustive graph expansion.

### Layout can become unstable as topology changes

**Risk:** The application list below the diagram may jump and nodes may swap.  
**Mitigation:** Use fixed-height modes, deterministic ordering, stable IDs, and short transitions.

### Translucent styling can reduce legibility

**Risk:** Flow bands and unavailable states may disappear against some desktops.  
**Mitigation:** Reuse `DashboardStyleAppearance`, respect accessibility fallbacks, keep semantic labels, and validate against varied backgrounds.

### Future endpoint kinds may outgrow current core enums

**Risk:** The current core endpoint type set is limited.  
**Mitigation:** Keep diagram kinds and mapping isolated in the presentation builder. A later core extension can add endpoint descriptors or measurement provenance without changing the view’s topology contract.

## 23. Rollout

The specification and implementation live on `feat/power-flow-diagram`, based on `next-version`. The completed feature should be reviewed and merged back into `next-version`, not directly into `main`.

No feature flag or migration is required because the change replaces only the Energy power-flow presentation and does not alter persisted preferences or stored data.

## 24. Final design decision

The first release will use a **general presentation model, four expanded shared-bus templates, and grouped-summary fallback**. It explicitly supports unknown and unavailable endpoints without inventing power values, while preserving a compact and stable macOS dashboard layout.
