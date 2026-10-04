# Multiple Power Flow Lanes Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement these tasks in this session. User approved the preceding in-chat design and requested smooth upper and lower transitions.

**Goal:** Adapt the four expanded power-flow topologies and uncertain/grouped states with smooth branch geometry and synchronized motion.

**Architecture:** Preserve the presentation builder and measurement service. Extend pure layout with source/bus/sink ribbon geometry, render a matching segmented surface, and reuse the observed 3.6-second pulse on each supported branch. Cubic upper/lower boundaries meet with horizontal tangents; feather the light inside each ribbon.

**Tech Stack:** SwiftUI, CoreGraphics, XCTest; macOS 13+.

**Reference priority:** The user subsequently rejected the ZIP concept sheet as a visual/animation target. Use the ZIP only for topology and data-state coverage. Match the supplied AlDente charging screenshot and the timestamped AlDente capture for appearance and motion. The charging reference has broad, gently bending lanes rather than a narrow waist.

**Spec:** User-approved design in this conversation plus `../specs/2026-09-22-power-flow-diagram-design.md`. This update supersedes that document's prohibition on continuous motion and its earlier height targets. Keep the compact 78 pt single-lane height, 384 pt reference width, and 320 pt expanded floor. Per the latest user clarification, expand two-lane topologies to 97.5 pt.

## Global Constraints

- Keep the established 1→1 motion and transparent endpoint separators.
- Use external yellow, battery green, Mac blue, and neutral unknown/bus colors.
- Two-node sides use a 20% gap within the active span and 80% combined ribbon thickness. Known complete readings determine branch proportions, with a minimum readable thickness; missing values use equal lanes.
- 2→2 has a shared bus, never pairwise source-to-sink allocations.
- No inferred readings or watt-dependent speed. Remove the ≈ prefix per user request; retain ≥, missing-side and partial-data semantics. Branch heights may reflect known power proportions.
- No active pulse on an unavailable/synthetic branch, or in hidden/Reduce Motion/terminal states.
- Preserve all pre-existing uncommitted work; changes remain available for review.

## Review Focus

- Both boundaries must have continuous tangents where branches meet trunks/bus.
- Footer cases must keep labels, icons and paths aligned above the reserved footer.
- Unavailable branches must remain identifiable without appearing to carry known power.
- Two branches must not double-paint the shared region or tint their separation gap.
- Battery-only, charging, multiple-source and grouped states must use their own palette.

## Task 1: Pure geometry and surface

- [x] Update existing layout tests: separated lanes and proportional gaps and a shared bus only for 2→2; observe failures.
- [x] Extend `PowerFlowDiagramLayoutResult` with `[PowerFlowRibbonGeometry]` and a real optional `busFrame`.
- [x] Add roles `.direct`, `.source(Int)`, `.sink(Int)`, `.bus` and cubic ribbon top/bottom boundaries.
- [x] Resolve 1→2 splitting, 2→1 merging and 2→2 merging/splitting with stable label regions and footer alignment.
- [x] Verify endpoint bounds, tangent continuity, branch gaps and label containment at 320–384 pt.

## Task 2: Branch colors, surfaces and activity

- [x] Add a rendered regression requiring green battery / blue Mac branches and a clear split gap; observe failure.
- [x] Add `PowerFlowDiagramRibbon.swift` for path/surface rendering, per-branch state and palette.
- [x] Integrate into `PowerFlowDiagramView.swift`; share the phase, feather both contour edges and draw shared surfaces once.
- [x] Gate the timeline on actual animated branches. Grouped summaries use a neutral pulse only with known positive contributions on both sides.
- [x] Verify all-unavailable and missing-counterpart behavior, battery-only color and unchanged direct flow.

## Task 3: Visual and integration verification

- [x] Export full motion cycles for all 16 fixtures at 384 pt; export the static content matrix in light/dark at 320/384 pt.
- [x] Inspect static and full-cycle exported frames, including enlarged split/merge edges.
- [x] Run the PowerFlow regression suite and `git diff --check`.
- [x] Build the Xcode app where the local environment permits; record actual results and visual evidence boundaries.

## Result

Implemented and verified. See `../verification/2026-10-02-power-flow-multiple-lanes.md` for the corrected reference interpretation, test results, and visual evidence limits.

## Latest screenshot refinement

The four new AlDente screenshots supersede the earlier contour proportions:

- Split at the left edge (0%); merge at the right edge (100%). No separate straight trunk in these two cases.
- Each branch retains its thickness and shifts vertically by half the gap, using full-width cubic curves with midpoint X controls.
- Center branch readouts horizontally; move rounded total watts under the single endpoint's icon.
- External power uses a lightning bolt; charging battery uses a battery-with-bolt symbol.
- Branch watt values keep two decimals; endpoint totals remain compact whole watts.
- Preserve compact single-lane height; grow the view only for additional branches.
