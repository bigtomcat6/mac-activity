# Power Flow screenshot contour refinement

## User direction

Use the four newly supplied AlDente screenshots. Remove the approximation symbol.
Keep the existing compact single-lane height, allowing extra height for branches.
The earlier planning ZIP remains a scenario inventory, not a visual target.

## Measured geometry

Coordinates below are approximate pixels from the source PNGs, before adapting
vertical dimensions to the compact Energy panel:

| Feature | Charging screenshot | Combined-power screenshot |
| --- | --- | --- |
| Middle channel X | 212–732 | 212–732 |
| Split/merge X | split begins at 212 | merge finishes at 732 |
| Upper outer boundary Y | 332 → 302 | 310 → 340 |
| Lower outer boundary Y | 572 → 602 | 610 → 580 |
| Gap at separated end | about 60 | about 60 |
| Upper/lower branch thickness | about 98/142 | about 112/128 |

The curves span the entire middle channel. Midpoint X controls with horizontal
endpoint tangents fit the observed gradual bend. The old 20% split and 62% merge
introduced straight trunks absent from these references.

At the user's chosen compact scale, a single lane remains 78 pt high. Two-lane
modes use 97.5 pt, containing 78 pt combined ribbon thickness plus a 19.5 pt gap.
Each branch shifts 9.75 pt vertically. Footer variants scale the active area.
A SwiftUI Layout negotiates height from the effective topology so sub-320 pt
summary mode stays compact instead of reserving unused expanded space.

Unequal branch thickness is visible in the references. Using known power ratios
is an inference, most clearly supported by the combined-power screenshot. The
implementation uses each side's complete readings, retains a readability floor,
and falls back to equal lanes if a reading is missing. It does not infer readings
or pairwise allocations. The four screenshots do not provide a new 2→2 reference;
that case continues to use the shared-bus treatment.

## Readouts and icons

- Removed `≈` from diagram formatting, including totals and hover values.
- Retained derived-data provenance in accessibility/help wording, plus `≥` and
  missing-value semantics.
- Branch readouts are centered across the channel, with two decimal places.
- Single-endpoint totals move under that endpoint's icon, rounded as `36W`/`61W`.
- External power uses the lightning symbol; a charging sink uses the charging
  battery symbol.
- Existing pulse timing and visibility/Reduce Motion gates remain in use.

## Verification

- Before the geometry/formatting fix: 13 selected tests, 15 assertion failures.
- Before two-decimal branch formatting: the charging fixture failed on `20.1 W`
  versus the required `20.10 W`.
- Final scoped run: **156 tests, 3 skipped, 0 failures**. This includes all
  PowerFlow tests and the dashboard chrome integration check.
- Xcode Debug app build, signing disabled: **BUILD SUCCEEDED**.
- `git diff --check`: passed.
- Exported 20 fixtures × 108 deterministic frames = **2,160 PNGs**; also exported
  the light/dark, standard/translucent, 320/384 pt content matrix.

The three skipped scoped tests require live SMC readings or native-window/glass
capture. The full test command was also run. It logged 15 failed cases below;
several explicitly lack NSScreen, NSRunningApplication or system metrics. Other
window assertions failed without a confirmed cause. Its log ends after starting
`StatusBarSummaryLayoutTests.testStatusItemLeftClickTogglesPopoverAndRightClickPresentsContextMenu`
without a final XCTest summary, despite the command returning exit status 0.
**The full suite is not verified passing.**

- `MacActivityAppTests.DashboardAdaptiveHostTests.testHostSwapKeepsTheSameContentViewControllerInstance`
- `MacActivityAppTests.DashboardAdaptiveHostTests.testHostSwitchDestroysHiddenPanelAndRecreatesForPanelAgain`
- `MacActivityAppTests.DashboardAdaptiveHostTests.testPerformCloseOnHiddenAttachedPanelDoesNotNotifyAgainOrDestroyIt`
- `MacActivityAppTests.DashboardAdaptiveHostTests.testStandardResolutionUsesPopoverHost`
- `MacActivityAppTests.DashboardAdaptiveHostTests.testTransparentRequestFallsBackToPopoverUnderReduceTransparencyAndReverses`
- `MacActivityAppTests.DashboardAdaptiveHostTests.testTransparentResolutionUsesPanelWithSharedContentViewController`
- `MacActivityAppTests.DashboardAdaptiveHostTests.testVisiblePanelContentSizeReadsAndResizesThroughPanelHost`
- `MacActivityAppTests.DashboardPanelHostTests.testLocalMouseClickInsidePanelWindowKeepsPanelVisible`
- `MacActivityAppTests.DashboardPopoverControllerTests.testHiddenPanelStopsPollingAndReopenResumesOnce`
- `MacActivityAppTests.DashboardPopoverControllerTests.testHostSwitchStopsPollingAcrossRootReparentingAndResumesWhenPresented`
- `MacActivityCoreTests.EnergyImpactProviderTests.testLiveCatalogAdapterReturnsUniquePositiveScopedSnapshots`
- `MacActivityCoreTests.MemoryProviderTests.testActiveAppMemoryServiceRejectsReusedPIDIdentityMismatch`
- `MacActivityCoreTests.MetricProviderSampleTests.testSwapProviderSamplesSystemSwapState`
- `MacActivityAppTests.PreferencesViewTests.testPreferencesWindowKeepsFixedWidthDuringNativeZoom`
- `DebugGlassPrototypeTests.PrototypeDismissalTests.testLocalMouseClickInsidePanelHierarchyDoesNotClose`

## Review artifacts

Directory:

`/Users/how/.codex/visualizations/2026/10/02/01a0fc83-d612-7d32-a31e-6537a84e9e97/powerflow-reference-refinement/`

- `reference-states.gif`: the four user-supplied scenarios using production
  SwiftUI panels, a fixed dark matte background, and a 3.6-second cycle.
- `reference-states.png`: the same panels at 2.1 seconds.
- `branch-keyframes.png`: four sampled phases of split and merge.
- `reference-measurements.json`: source-coordinate measurements and normalized
  compact geometry.
- `final-tests.log`, `full-tests.log`, `xcode.log`, `refinement-red.log`,
  `precision-red.log`: command evidence.

These are deterministic fixture renders, not live Energy-window/native-glass
captures. The source screenshot aspect ratio is intentionally compressed
vertically to preserve the user's compact-height preference.

Changes remain uncommitted; no release or deployment was performed.
