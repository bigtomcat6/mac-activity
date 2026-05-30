# Overview Layout Refactor Design

## Context

The Overview tab currently renders every available `DashboardMetric` as a single vertical list of `MetricCard` views. Each chart-style card uses the same compact chart layout, and Memory uses the existing stacked memory trend chart.

The refactor keeps the existing data model and trend-chart behavior, but changes Overview into a fixed dashboard layout that groups metrics by visual priority.

## Requirements

- Create the refactor branch from latest `origin/main`: `refactor/overview-layout`.
- Keep the Actives tab and cleanup behavior out of scope.
- Keep Memory as the existing trend/stacked-memory chart, not a gauge.
- Keep CPU Temp and Fan as trend charts, not gauges.
- Change CPU Temp and Fan card layout to text on the left and a compact trend chart on the right.
- Keep the third Overview region temporarily as Battery only.

## Considered Approaches

### Recommended: fixed Overview sections over existing metrics

Use the existing `[DashboardMetric]` data from `DashboardModel`, build a lookup by `MetricKind` in `DashboardView`, and render fixed sections in the requested order. This preserves the existing provider, history, formatter, and chart code while making the layout deterministic.

Tradeoff: missing metrics leave gaps or are omitted by section rules. This is acceptable because unavailable providers already omit cards today.

### Alternative: add section structure to `DashboardModel`

Have `DashboardModel` publish a sectioned Overview model rather than a flat metric list. This would make the view simpler, but it pushes presentational grouping into the core presentation model and increases blast radius.

### Alternative: keep the list and only sort/group visually

Continue rendering a `ForEach` over metrics and add ad hoc layout conditions while iterating. This is the least invasive but makes the resulting layout harder to reason about because row composition depends on iteration side effects.

## Approved Design

Overview renders three vertical regions:

1. Region one is a two-column row.
   - Left: combined CPU/GPU usage card.
   - Right: Memory card using the existing stacked-memory trend chart.

2. Region two is a two-column row.
   - Left: Network card using the existing trend chart.
   - Right: vertical stack with CPU Temp and Fan compact cards.
   - CPU Temp and Fan cards show text/value on the left and the trend chart on the right.

3. Region three contains Battery only.
   - Battery keeps the existing trend chart style.

CPU/GPU are the only widgets that move away from the existing chart card style. Their combined card displays one row for CPU and one row for GPU, each with label, current percent, and a horizontal progress bar.

## Component Boundaries

- `DashboardView` remains responsible for Overview tab composition.
- Existing `DashboardTrendChart`, `RAMSegmentBars`, and formatter behavior should be reused.
- Add small focused view components in `DashboardView.swift` unless the file becomes unwieldy during implementation.
- Keep `DashboardModel` flat unless tests reveal a strong reason to move layout grouping into core presentation.

## Data Flow

`DashboardModel.metrics` continues to be the single source of Overview data. `DashboardView` maps metrics by `MetricKind` and conditionally renders each fixed slot when the corresponding metric is available.

CPU/GPU progress bars use the existing metric value text for display and derive clamped progress from the percent string or a small view-local helper. Chart cards continue to receive the original `DashboardMetric` and its trend data.

## Empty and Missing Data

- If all metrics are missing, keep the existing empty state.
- If one metric in a fixed slot is unavailable, omit that specific widget rather than rendering placeholder charts.
- If CPU or GPU is missing, the combined usage card should still render the available row.
- If both CPU and GPU are missing, omit the combined usage card.

## Testing

Use test-first implementation.

Focused tests should cover:

- Overview section planning/order from a representative metric list.
- CPU/GPU usage progress clamps to `0...1` and handles missing/non-percent values safely.
- CPU/GPU combined card reports availability correctly when either metric exists.
- Existing Memory, Network, CPU Temp, Fan, and Battery metrics keep chart-style rendering paths.
- CPU Temp and Fan compact layout constants encode left-text/right-chart shape.

Verification commands:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test
```

If SwiftPM reports `sandbox_apply: Operation not permitted` inside Codex sandbox, rerun the same command with sandbox escalation.
