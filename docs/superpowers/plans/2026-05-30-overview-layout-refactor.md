# Overview Layout Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recompose the Overview tab into the approved three-region dashboard while preserving existing trend chart behavior for Memory, Network, CPU Temp, Fan, and Battery.

**Architecture:** Keep `DashboardModel.metrics` flat and make `DashboardView` responsible for fixed Overview composition. Add small internal layout helpers for deterministic slot ordering and CPU/GPU progress parsing, then build focused SwiftUI subviews for the combined CPU/GPU usage card and compact text-left/chart-right trend cards.

**Tech Stack:** Swift 6.2, SwiftUI, Charts, XCTest, Swift Package Manager.

---

## Scope And Files

Spec: `docs/superpowers/specs/2026-05-30-overview-layout-refactor-design.md`

Modify:
- `Sources/MacActivityApp/Views/DashboardView.swift`
  - Add `DashboardOverviewSlot` and `DashboardOverviewLayout` helpers.
  - Replace the flat Overview `ForEach` with fixed sections.
  - Add CPU/GPU usage card and compact trend card views.
  - Reuse existing `MetricCard`, `DashboardTrendChart`, and `RAMSegmentBars` for chart behavior.
- `Tests/MacActivityAppTests/DashboardCardLayoutTests.swift`
  - Add focused tests for slot planning, CPU/GPU progress parsing, and compact trend layout constants.

Do not modify:
- `Sources/MacActivityCore/Presentation/DashboardModel.swift`
- Actives cleanup files.
- Metric providers or history storage.

## Commands

Targeted tests:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests
```

Full verification:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test
```

If SwiftPM fails inside Codex with `sandbox_apply: Operation not permitted`, rerun the same command with sandbox escalation.

---

## Chunk 1: Overview Slot Planning

### Task 1: Add deterministic Overview slot planning

**Files:**
- Modify: `Tests/MacActivityAppTests/DashboardCardLayoutTests.swift`
- Modify: `Sources/MacActivityApp/Views/DashboardView.swift`

- [ ] **Step 1: Write the failing layout planning tests**

Add these tests to `DashboardCardLayoutTests`:

```swift
func testOverviewLayoutUsesApprovedFixedSlots() {
    let metrics = DashboardCardLayoutTests.overviewMetrics([
        .cpu,
        .gpu,
        .memory,
        .network,
        .temperature,
        .fan,
        .battery,
    ])

    XCTAssertEqual(
        DashboardOverviewLayout.topRowSlots(for: metrics),
        [.usage, .metric(.memory)]
    )
    XCTAssertEqual(
        DashboardOverviewLayout.secondRowLeadingSlot(for: metrics),
        .metric(.network)
    )
    XCTAssertEqual(
        DashboardOverviewLayout.secondRowTrailingSlots(for: metrics),
        [.metric(.temperature), .metric(.fan)]
    )
    XCTAssertEqual(
        DashboardOverviewLayout.thirdRowSlots(for: metrics),
        [.metric(.battery)]
    )
}

func testOverviewLayoutOmitsUnavailableSlotsAndKeepsBatteryOnlyThirdRegion() {
    let metrics = DashboardCardLayoutTests.overviewMetrics([.cpu, .memory, .fan, .vram])

    XCTAssertEqual(
        DashboardOverviewLayout.topRowSlots(for: metrics),
        [.usage, .metric(.memory)]
    )
    XCTAssertNil(DashboardOverviewLayout.secondRowLeadingSlot(for: metrics))
    XCTAssertEqual(
        DashboardOverviewLayout.secondRowTrailingSlots(for: metrics),
        [.metric(.fan)]
    )
    XCTAssertEqual(DashboardOverviewLayout.thirdRowSlots(for: metrics), [])
}

private static func overviewMetrics(_ kinds: [MetricKind]) -> [DashboardMetric] {
    kinds.map { kind in
        DashboardMetric(
            kind: kind,
            title: kind.title,
            value: kind == .fan ? "1800 RPM" : "42%",
            style: kind == .memory ? .memoryStackedChart : .chart
        )
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests/testOverviewLayout
```

Expected: compile failure because `DashboardOverviewLayout` and `DashboardOverviewSlot` do not exist.

- [ ] **Step 3: Implement the minimal layout helpers**

Add these internal helpers near `DashboardCardLayout` in `DashboardView.swift`:

```swift
enum DashboardOverviewSlot: Equatable {
    case usage
    case metric(MetricKind)
}

enum DashboardOverviewLayout {
    static func metricsByKind(_ metrics: [DashboardMetric]) -> [MetricKind: DashboardMetric] {
        Dictionary(uniqueKeysWithValues: metrics.map { ($0.kind, $0) })
    }

    static func topRowSlots(for metrics: [DashboardMetric]) -> [DashboardOverviewSlot] {
        let byKind = metricsByKind(metrics)
        var slots: [DashboardOverviewSlot] = []
        if hasUsageMetric(in: byKind) { slots.append(.usage) }
        if byKind[.memory] != nil { slots.append(.metric(.memory)) }
        return slots
    }

    static func secondRowLeadingSlot(for metrics: [DashboardMetric]) -> DashboardOverviewSlot? {
        metricsByKind(metrics)[.network] == nil ? nil : .metric(.network)
    }

    static func secondRowTrailingSlots(for metrics: [DashboardMetric]) -> [DashboardOverviewSlot] {
        let byKind = metricsByKind(metrics)
        return [MetricKind.temperature, .fan].compactMap { kind in
            byKind[kind] == nil ? nil : .metric(kind)
        }
    }

    static func thirdRowSlots(for metrics: [DashboardMetric]) -> [DashboardOverviewSlot] {
        metricsByKind(metrics)[.battery] == nil ? [] : [.metric(.battery)]
    }

    static func hasUsageMetric(in metricsByKind: [MetricKind: DashboardMetric]) -> Bool {
        metricsByKind[.cpu] != nil || metricsByKind[.gpu] != nil
    }
}
```

- [ ] **Step 4: Run the targeted tests and verify GREEN**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests/testOverviewLayout
```

Expected: the two new Overview layout tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/MacActivityApp/Views/DashboardView.swift Tests/MacActivityAppTests/DashboardCardLayoutTests.swift
git commit -m "test: cover overview layout planning"
```

---

## Chunk 2: CPU/GPU Usage Bars

### Task 2: Add CPU/GPU progress parsing and combined usage card

**Files:**
- Modify: `Tests/MacActivityAppTests/DashboardCardLayoutTests.swift`
- Modify: `Sources/MacActivityApp/Views/DashboardView.swift`

- [ ] **Step 1: Write the failing progress tests**

Add:

```swift
func testOverviewUsageProgressParsesPercentTextAndClamps() {
    XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "38%"), 0.38, accuracy: 0.001)
    XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "0%"), 0.0, accuracy: 0.001)
    XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "147%"), 1.0, accuracy: 0.001)
    XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "-7%"), 0.0, accuracy: 0.001)
    XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "Collecting"), 0.0, accuracy: 0.001)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests/testOverviewUsageProgress
```

Expected: compile failure because `usageProgress(for:)` does not exist.

- [ ] **Step 3: Implement progress parsing**

Add to `DashboardOverviewLayout`:

```swift
static func usageProgress(for value: String) -> Double {
    let percentText = value.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "%", with: "")
    guard let percent = Double(percentText) else { return 0 }
    return min(max(percent / 100, 0), 1)
}
```

- [ ] **Step 4: Add the combined usage card views**

Add private views near `MetricCard`:

```swift
private struct CPUGPUUsageCard: View {
    let cpu: DashboardMetric?
    let gpu: DashboardMetric?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CPU / GPU")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let cpu {
                UsageBarRow(metric: cpu, color: DashboardMetricColor.color(for: .cpu))
            }
            if let gpu {
                UsageBarRow(metric: gpu, color: DashboardMetricColor.color(for: .gpu))
            }
        }
        .padding(DashboardCardLayout.regularCardInsets)
        .frame(maxWidth: .infinity, minHeight: DashboardCardLayout.compactChartMinHeight, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct UsageBarRow: View {
    let metric: DashboardMetric
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(metric.title)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Spacer(minLength: 8)
                Text(metric.value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color.opacity(0.82))
                        .frame(width: proxy.size.width * DashboardOverviewLayout.usageProgress(for: metric.value))
                }
            }
            .frame(height: 8)
        }
    }
}
```

Extract the current `MetricCard.color` switch into an internal helper:

```swift
enum DashboardMetricColor {
    static func color(for kind: MetricKind) -> Color {
        switch kind {
        case .cpu: return .orange
        case .gpu: return .purple
        case .memory: return .blue
        case .vram: return .cyan
        case .network: return .teal
        case .battery: return .green
        case .temperature: return .red
        case .fan: return .indigo
        }
    }
}
```

Then change `MetricCard.color` to:

```swift
private var color: Color {
    DashboardMetricColor.color(for: metric.kind)
}
```

- [ ] **Step 5: Run targeted tests and verify GREEN**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests/testOverviewUsageProgress
```

Expected: progress parsing tests pass.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/MacActivityApp/Views/DashboardView.swift Tests/MacActivityAppTests/DashboardCardLayoutTests.swift
git commit -m "feat: add overview cpu gpu usage card"
```

---

## Chunk 3: Fixed Overview Composition

### Task 3: Render the approved three-region Overview layout

**Files:**
- Modify: `Tests/MacActivityAppTests/DashboardCardLayoutTests.swift`
- Modify: `Sources/MacActivityApp/Views/DashboardView.swift`

- [ ] **Step 1: Write the failing compact layout constant test**

Add:

```swift
func testOverviewCompactTrendLayoutUsesTextLeftChartRightShape() {
    XCTAssertEqual(DashboardOverviewLayout.compactTrendTextWidth, 84)
    XCTAssertEqual(DashboardOverviewLayout.compactTrendChartHeight, 44)
    XCTAssertEqual(DashboardOverviewLayout.sectionSpacing, 12)
}
```

- [ ] **Step 2: Run the test and verify RED if constants are not yet in place**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests/testOverviewCompactTrendLayout
```

Expected: fail if the constants are missing or differ from the approved shape.

- [ ] **Step 3: Add Overview section constants**

Add to `DashboardOverviewLayout`:

```swift
static let sectionSpacing: CGFloat = 12
static let topRowColumns = [GridItem(.flexible()), GridItem(.flexible())]
static let secondRowColumns = [GridItem(.flexible(minimum: 0), spacing: 12), GridItem(.flexible(minimum: 0), spacing: 12)]
static let compactTrendTextWidth: CGFloat = 84
static let compactTrendChartHeight: CGFloat = 44
```

- [ ] **Step 4: Replace the flat Overview content with fixed sections**

In `DashboardView.overviewContent`, replace the flat `ForEach(dashboardModel.metrics)` content with a dedicated view:

```swift
private var overviewContent: some View {
    OverviewDashboardContent(metrics: dashboardModel.metrics)
        .padding(18)
}
```

Add:

```swift
private struct OverviewDashboardContent: View {
    let metrics: [DashboardMetric]

    private var metricsByKind: [MetricKind: DashboardMetric] {
        DashboardOverviewLayout.metricsByKind(metrics)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DashboardOverviewLayout.sectionSpacing) {
            if metrics.isEmpty {
                emptyState
            } else {
                topRegion
                secondRegion
                batteryRegion
            }
        }
    }

    private var hasSecondRegion: Bool {
        metricsByKind[.network] != nil || metricsByKind[.temperature] != nil || metricsByKind[.fan] != nil
    }

    private var topRegion: some View {
        LazyVGrid(columns: DashboardOverviewLayout.topRowColumns, spacing: DashboardOverviewLayout.sectionSpacing) {
            if DashboardOverviewLayout.hasUsageMetric(in: metricsByKind) {
                CPUGPUUsageCard(cpu: metricsByKind[.cpu], gpu: metricsByKind[.gpu])
            }
            if let memory = metricsByKind[.memory] {
                MetricCard(metric: memory)
            }
        }
    }

    @ViewBuilder
    private var secondRegion: some View {
        if hasSecondRegion {
            LazyVGrid(columns: DashboardOverviewLayout.secondRowColumns, spacing: DashboardOverviewLayout.sectionSpacing) {
                if let network = metricsByKind[.network] {
                    MetricCard(metric: network)
                }
                if metricsByKind[.temperature] != nil || metricsByKind[.fan] != nil {
                    VStack(spacing: DashboardOverviewLayout.sectionSpacing) {
                        if let temperature = metricsByKind[.temperature] {
                            CompactTrendMetricCard(metric: temperature)
                        }
                        if let fan = metricsByKind[.fan] {
                            CompactTrendMetricCard(metric: fan)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var batteryRegion: some View {
        if let battery = metricsByKind[.battery] {
            MetricCard(metric: battery)
        }
    }

    private var emptyState: some View {
        Text("Waiting for the first metric sample.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
```

If SwiftUI type-checking complains about empty `LazyVGrid` regions, split each region into `@ViewBuilder` properties and only render a row when its required slot exists.

- [ ] **Step 5: Add the compact text-left/chart-right trend card**

Add:

```swift
private struct CompactTrendMetricCard: View {
    let metric: DashboardMetric
    @State private var isCardHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metric.value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: DashboardOverviewLayout.compactTrendTextWidth, alignment: .leading)

            DashboardTrendChart(
                metric: metric,
                color: DashboardMetricColor.color(for: metric.kind),
                isCardHovered: isCardHovered
            )
            .frame(height: DashboardOverviewLayout.compactTrendChartHeight)
        }
        .padding(DashboardCardLayout.compactChartInsets)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .onHover { hovering in
            isCardHovered = hovering
        }
    }
}
```

- [ ] **Step 6: Run Dashboard card tests**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests
```

Expected: all Dashboard card layout tests pass.

- [ ] **Step 7: Commit**

Run:

```bash
git add Sources/MacActivityApp/Views/DashboardView.swift Tests/MacActivityAppTests/DashboardCardLayoutTests.swift
git commit -m "refactor: compose overview dashboard sections"
```

---

## Chunk 4: Verification

### Task 4: Run full verification and inspect final diff

**Files:**
- No planned file edits unless verification exposes issues.

- [ ] **Step 1: Run full test suite**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test
```

Expected: all tests pass. Baseline before implementation was 146 XCTest tests passing.

- [ ] **Step 2: Check formatting and whitespace**

Run:

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 3: Review the diff for scope**

Run:

```bash
git diff --stat origin/main...HEAD
git diff origin/main...HEAD -- Sources/MacActivityApp/Views/DashboardView.swift Tests/MacActivityAppTests/DashboardCardLayoutTests.swift
```

Expected: only the Overview layout refactor, tests, and superpowers docs are changed.

- [ ] **Step 4: Report completion**

Summarize:
- Branch and worktree path.
- Commits created.
- Tests run and exact pass/fail result.
- Any known visual verification gap if the app was not launched.
