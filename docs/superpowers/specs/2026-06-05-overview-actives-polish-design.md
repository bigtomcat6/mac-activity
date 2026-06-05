# Overview And Actives Polish Design

## Goal

Tighten three UI polish issues in the MacActivity dashboard popover without changing the overall information architecture:

1. Make the `Overview` CPU/GPU usage rows feel horizontally centered within each row.
2. Remove the perceived delay when `Overview` trend-chart colors return to the active-state palette after the popover regains focus.
3. Make `Actives` process rows feel like one cohesive card system while preserving the current row-based list structure and interactions.

## Requested Scope

This design covers only the dashboard popover surfaces inside `MacActivityApp`:

- `Overview` usage card row layout
- `Overview` trend-chart active/inactive color transitions
- `Actives` process-row chrome

This design does not change:

- Overview card ordering, region structure, or metric inventory
- Temp/Fan/Battery hover behavior
- Metrics sampling cadence, history retention, or chart-domain smoothing rules
- Actives row height, quit-confirm workflow, or process data sourcing

## Current State

### CPU/GPU usage rows

`CPUGPUUsageCard` renders `UsageBarRow` entries using a flexible `HStack` with `Spacer`. That keeps the title on the left and the numeric value on the right, but the row's visual center shifts based on text width. The issue is not the card's placement inside the Overview grid; it is the internal alignment of each CPU/GPU row.

### Trend-chart focus restoration

`DashboardTrendChart` derives active vs inactive colors from `appearsActive`, but the chart view also animates hover state, sample changes, and displayed-domain changes. The perceived lag is limited to Overview trend charts, not to the CPU/GPU progress bars or memory card. The likely failure mode is that color-bearing chart content is being updated under the same animation umbrella as data-shape transitions, so the color appears to trail focus restoration.

### Actives process rows

`ActiveProcessMemoryList` currently separates rows primarily with `Divider`. Each `ActiveProcessMemoryRow` has a progress-fill layer, but the row itself does not have strong per-row chrome. The result is readable but slightly fragmented: rows feel like text sitting on a shared background rather than coordinated row surfaces within one system.

## Selected Direction

The approved visual direction is the balanced middle path:

- For CPU/GPU rows, use a stable three-column row structure.
- For trend charts, make active/inactive color-state recovery immediate while preserving data-motion animations.
- For Actives rows, preserve distinct rows but add subtle per-row chrome so they read as part of the same card family.

This keeps the UI close to the existing visual language and avoids a broader redesign.

## Design

### 1. Overview CPU/GPU row alignment

#### Intent

Each CPU/GPU row should have a stable horizontal center regardless of title/value width, while still allowing the progress bar to occupy most of the row width.

#### Proposed structure

Replace the current flexible left/right `HStack` behavior inside `UsageBarRow` with a three-column layout:

- Fixed leading column for the metric title
- Flexible center column for the progress bar
- Fixed trailing column for the percentage value

The title and value should each be horizontally centered within their own columns. The bar remains visually dominant because only the center column expands.

#### Boundary

This change belongs inside `UsageBarRow` and, if needed, a small `DashboardOverviewLayout` helper for shared constants such as leading/trailing column widths or row spacing. `CPUGPUUsageCard` remains the owner of the surrounding card chrome, padding, and row stacking.

#### Why this approach

This solves the actual issue the user called out: row-internal centering drift. It avoids changing the top-row grid, the usage card footprint, or the overall hierarchy of CPU/GPU relative to Memory.

### 2. Overview trend-chart focus color behavior

#### Intent

When the popover regains focus, Overview trend charts should immediately return to their active palette. The visual motion of incoming samples, domain changes, and hover changes can stay animated, but focus-state color restoration should not appear delayed.

#### Proposed behavior

Separate color-state changes from data-motion changes inside `DashboardTrendChart`:

- Keep sample animations for `trend.samples`
- Keep domain animation for `displayedDomain`
- Keep hover animation for hover-specific annotations/layout
- Avoid animating the active/inactive palette transition for chart strokes, area fills, and selection markers when `appearsActive` changes

In practice, the chart should recompute active colors immediately from `appearsActive`, rather than letting those color changes ride along with sample/domain animation transactions.

#### Boundary

This change belongs in `DashboardTrendChart` and its existing color helpers in `DashboardOverviewChrome`. It should not require changes to `DashboardModel`, `MetricsStore`, or sampling policy. It also should not alter the chart sampling/downsampling logic.

#### Why this approach

The user only reported a palette-timing problem in trend charts after focus restoration. Changing model activity, data refresh timing, or chart geometry would broaden scope into unrelated behavior and risk regressions in previously tuned Overview cards.

### 3. Actives row cohesion

#### Intent

Each process row should still read as a separate row, but the full list should feel like one polished card system instead of text lines separated mostly by dividers.

#### Proposed behavior

Add subtle row-level chrome to `ActiveProcessMemoryRow`:

- A soft row background tint that sits above the shared card background
- A light border or edge definition that is weaker than a standalone card border
- Hover, progress fill, and quit-confirm state must continue to layer correctly on top of or within this chrome

The list may retain minimal separation between rows, but the divider should stop doing most of the visual work. The rows themselves should carry more of the structure.

#### Boundary

This belongs in `ActiveProcessMemoryRow` with supporting constants in `ActiveProcessMemoryLayout` or `ActiveCleanReleaseLayout`. `ActiveProcessMemoryList` remains the owner of list composition, empty state, and process action message rendering.

#### Why this approach

This matches the approved direction: keep rows distinct, but make them feel like part of one card family. It improves cohesion without changing density, interactions, or the current cleanup-page composition.

## Units And Responsibilities

### `DashboardOverviewLayout` and related layout tokens

Responsibility:

- Hold stable layout constants for Overview row internals

Primary file:

- `Sources/MacActivityApp/Views/DashboardView.swift`

Expected additions:

- CPU/GPU row column sizing constants if the implementation benefits from explicit shared widths

This unit should remain a small token/helper seam. It should not absorb chart behavior or Actives styling.

### `UsageBarRow`

Responsibility:

- Render a single CPU or GPU row with title, progress bar, and value

Primary file:

- `Sources/MacActivityApp/Views/DashboardView.swift`

Expected changes:

- Adopt the fixed-leading / flexible-center / fixed-trailing layout
- Preserve current typography and progress-bar behavior unless a small spacing adjustment is needed to support the new alignment

This unit should not own outer card padding or unrelated active/inactive chart rules.

### `DashboardTrendChart`

Responsibility:

- Render Overview and dashboard trend charts, hover behavior, annotations, and chart-specific visual motion

Primary file:

- `Sources/MacActivityApp/Views/DashboardTrendChart.swift`

Expected changes:

- Ensure `appearsActive` palette changes are immediate
- Preserve existing animation behavior for hover/sample/domain transitions

This unit should not take on model-focus lifecycle or data-refresh orchestration.

### `ActiveProcessMemoryRow`

Responsibility:

- Render one process row, its progress fill, hover/quit behavior, and row-local chrome

Primary files:

- `Sources/MacActivityApp/Views/ActiveProcessMemoryRow.swift`
- `Sources/MacActivityApp/Views/ActiveProcessMemoryLayout.swift`

Expected changes:

- Introduce subtle row-local background/border treatment
- Maintain correct z-order with progress fill, text, buttons, and hover state

This unit should not take ownership of inter-row list management or process data fetching.

## Edge Cases

### CPU-only or GPU-only usage card

If only one of CPU/GPU is present, the remaining row should still use the same three-column structure and look visually centered.

### Longer localized labels or values

The fixed title/value columns must remain wide enough for the existing localized row content at typical sizes. If truncation is possible, it should degrade gracefully without reintroducing center drift.

### Focus changes while charts are already animating

If the popover regains focus during a sample or domain animation, color should still switch immediately to the active palette rather than waiting for that animation transaction to settle.

### Row hover and confirm states in Actives

The new row chrome must not obscure:

- The progress fill
- The hover-triggered trailing action swap
- The red confirm state when quitting a process

## Testing Strategy

### Overview layout tests

Extend `Tests/MacActivityAppTests/DashboardCardLayoutTests.swift` to cover:

- Stable constants for the CPU/GPU row columns if new layout tokens are introduced
- The intended “structured row, not spacer-driven drift” layout contract at the helper/token level

### Overview active/inactive chart tests

Add or extend tests around `DashboardOverviewChrome` / `DashboardTrendChart` behavior to prove:

- Inactive and active palette values still differ as intended
- Focus-state color changes are not tied to sample/domain animation assumptions

The tests should stay robust and avoid brittle pixel-perfect chart assertions where possible.

### Actives row tests

Extend:

- `Tests/MacActivityAppTests/ActiveProcessMemoryLayoutTests.swift`
- `Tests/MacActivityAppTests/ActiveCleanReleaseViewTests.swift`

to cover:

- New row chrome constants or helpers
- The fact that row-level surfaces remain compatible with current hover and inactive-state rendering

## Risks And Mitigations

### Risk: the CPU/GPU row fix accidentally changes card density

Mitigation:

- Keep the fix local to row internals
- Reuse existing typography and bar height unless spacing must change slightly for alignment quality

### Risk: trend-chart color timing is “fixed” by disabling too many animations

Mitigation:

- Only decouple palette restoration from focus changes
- Preserve sample, hover, and domain motion paths

### Risk: new Actives row chrome fights with progress-fill readability

Mitigation:

- Keep row chrome subtle and verify it visually complements, rather than overpowers, the fill layer

## Implementation Readiness

This design is ready to turn into a single implementation plan because:

- All requested changes are within the dashboard popover UI surface
- Each change has a clear owner file and local boundary
- Out-of-scope items are explicit, reducing the chance of opportunistic refactors

The implementation plan should break work into three focused tasks plus verification:

1. CPU/GPU row alignment
2. Trend-chart focus color timing
3. Actives row chrome
4. Focused regression tests and validation
