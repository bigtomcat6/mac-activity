Branch: `feat/power-flow-diagram`
HEAD: `6cd2742fc7ef03d9fde203dca8bd4d5262dbc509`
Date: `2026-09-22` (AEST)

# Power Flow diagram — independent Task 8 verification

## Verdict and scope

**Automated checks PASS; complete visual/live acceptance NOT_VERIFIED.** This is evidence, not approval to advance the spec or mark Task 8 fully complete.

- All six required focused commands passed. Full SwiftPM: **1,703 tests, four explicit skips, zero failures** (1,699 non-skipped tests).
- Exact plan Xcode application build: **BUILD SUCCEEDED**, exit 0, signing disabled. XcodeGen reproduced the committed project exactly; working-tree whitespace checks passed. The later branch-wide whitespace correction is recorded below.
- Native opt-in gate: **PASS**, one test, three real captured readings, no skip. This verifies telemetry/service behavior, not application appearance.
- Freshly exported **50 PNGs: 42 baseline + 8 supplemental**. Independently opened **each of the 50 raw PNGs** with the image-read tool, then opened five native diagnostic composite sheets covering all 50.
- **22 translucent samples PASS only for static content/layout on the diagnostic neutral backgrounds.** Raw alpha display did not establish readability; compositing the same bytes recovered the content.
- **28 standard samples NOT_VERIFIED (FAIL as visual evidence): blank content remains blank after compositing.** This includes all six baseline 320-point pressure-width images. Export/non-nil/image dimensions are not approval.
- No confirmed product layout defect in the 22 viewable composites. Standard native-glass appearance, live accessibility behavior, varied-desktop contrast, and the baseline pressure-width matrix remain unverified.
- No production edits, test-source edits, commits, pushes, subagents, spec advancement, preference toggles, or power-state changes.

Workdir: `/Users/how/Git/How/How/MacActivity/worktrees/power-flow-diagram`.

Environment: macOS 26.4.1 (25E253), Xcode 26.3 (17C529), SDK `MacOSX26.2.sdk`, Apple Swift 6.2.4, arm64, XcodeGen 2.45.3. This is not a macOS 13 runtime validation.

## Automated command results

Each timed command was wrapped in `/usr/bin/time -p`; stdout/stderr were retained separately in [`.build/task8-verification`](../../../.build/task8-verification). Exit values below are the command results captured immediately with `$?`, not the subsequent reporting `printf` result. Times are seconds; `real` includes build/startup. Final summaries below are copied verbatim from XCTest (the later Swift Testing banner reports zero tests because these tests use XCTest).

| Command | Exit | Result | Tests / skips | Real / user / sys | Exact final substantive summary |
|---|---:|---|---|---|---|
| `swift test --filter PowerFlowDiagram` | 0 | PASS, gated skip | 56 / 1 | 1.20 / 0.81 / 0.33 | `Executed 56 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.197 (0.200) seconds` |
| `swift test --filter PowerFlowViewTests` | 0 | PASS | 3 / 0 | 0.49 / 0.32 / 0.13 | `Executed 3 tests, with 0 failures (0 unexpected) in 0.058 (0.059) seconds` |
| `swift test --filter PowerFlowModelTests` | 0 | PASS | 7 / 0 | 0.43 / 0.28 / 0.12 | `Executed 7 tests, with 0 failures (0 unexpected) in 0.002 (0.003) seconds` |
| `swift test --filter PowerFlowServiceTests` | 0 | PASS | 16 / 0 | 0.43 / 0.29 / 0.12 | `Executed 16 tests, with 0 failures (0 unexpected) in 0.002 (0.004) seconds` |
| `swift test --filter PowerFlowPresentationTests` | 0 | PASS | 11 / 0 | 0.46 / 0.30 / 0.13 | `Executed 11 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds` |
| `swift test --filter LocalizationTests` | 0 | PASS | 39 / 0 | 0.94 / 0.74 / 0.14 | `Executed 39 tests, with 0 failures (0 unexpected) in 0.491 (0.493) seconds` |
| `swift test` | 0 | PASS, four explicit skips | 1703 / 4 | 66.32 / 26.43 / 1.97 | `Executed 1703 tests, with 4 tests skipped and 0 failures (0 unexpected) in 65.824 (65.910) seconds` |
| `xcodebuild -project MacActivity.xcodeproj -scheme MacActivity -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | 0 | PASS | N/A | 19.30 / 3.36 / 1.63 | `** BUILD SUCCEEDED **` |
| `xcodegen generate` | 0 | PASS | N/A | 0.06 / 0.03 / 0.01 | `Created project at /Users/how/Git/How/How/MacActivity/worktrees/power-flow-diagram/MacActivity.xcodeproj` |
| `git diff --exit-code -- MacActivity.xcodeproj/project.pbxproj` | 0 | PASS | N/A | Not timed | No output; generated project unchanged |
| `git diff --check` | 0 | PASS | N/A | Not timed | No output |
| `MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT="$PWD/.build/power-flow-visual-matrix" swift test --filter PowerFlowDiagramVisualValidationTests/testExportVisualMatrixWhenExplicitlyRequested` | 0 | PASS: export only | 1 / 0 | 1.14 / 0.83 / 0.31 | `Executed 1 test, with 0 failures (0 unexpected) in 0.265 (0.266) seconds` |

Incremental Swift build times, in table order for the six filters: 0.41, 0.08, 0.08, 0.08, 0.08, 0.08 seconds; full suite 0.08 seconds; export 0.36 seconds. Focused test counts overlap; they are not an additional unique-test total.

Full suite ran 17:56:16.978–17:57:22.888 AEST. Explicit full-suite skip reasons:

| Test | Exact reason | Attribution |
|---|---|---|
| `DashboardPopoverControllerTests/testVisiblePopoverUsesWorkspaceReduceMotionByDefault` | `Workspace Reduce Motion is disabled.` | Pre-existing environment-dependent test; setting independently observed false. Not toggled. |
| `EnergyImpactNativeValidationTests/testVisibleFacadeBudget` | `Set MACACTIVITY_ENERGY_NATIVE_VALIDATION=1 explicitly` | Pre-existing, unrelated opt-in gate. Not broadened into energy testing. |
| `PowerFlowDiagramVisualValidationTests/testExportVisualMatrixWhenExplicitlyRequested` | `Set MACACTIVITY_POWER_FLOW_VISUAL_OUTPUT to export PNG evidence` | Intentional Task 8 infrastructure gate; separately enabled and passed. |
| `PowerFlowNativeValidationTests/testLiveSMCPowerFlowUsesCapturedReading` | `Set MACACTIVITY_POWER_FLOW_NATIVE_VALIDATION=1 explicitly` | Intentional native gate; separately enabled and passed. |

No failed tests or failed Xcode build required a product fix. Build diagnostics were investigated, not silently omitted:

- Sparkle cache warning: `skipping cache due to an error: Couldn’t fetch updates from remote repositories:` followed by `fatal: not a git repository (or any of the parent directories): .git`. Xcode recovered by creating a working copy and checking out Sparkle 2.9.3. Most likely a local package-cache checkout problem, not a Power Flow source regression; build succeeded without intervention. The cache's underlying corruption was not repaired or conclusively traced.
- `DashboardPanelSupport.swift:170:83`: non-Sendable notification `handler` captured in a `@Sendable` closure. Pre-existing source, unchanged from `77d9536`; Task 6 also reported it. No change introduced here.
- Two AppIntents metadata-extraction warnings: no `AppIntents.framework` dependency. Non-fatal build-tool diagnostic, not a diagram failure.
- Multiple matching macOS destinations: Xcode selected arm64 first. Exact requested destination command was preserved.

## Native gate: PASS, not skipped

Command: `MACACTIVITY_POWER_FLOW_NATIVE_VALIDATION=1 swift test --filter PowerFlowNativeValidationTests` (executed through `env`). Exit **0**; real/user/sys **7.10 / 0.67 / 0.31 s**; build **0.43 s**.

`Executed 1 test, with 0 failures (0 unexpected) in 6.056 (6.057) seconds`

Exact captured output, columns timestamp / input W / absolute battery W / Mac W:

```text
1790063873.581334 34.34349526559049 0.0 34.34349526559049
1790063876.606101 18.114063599974315 0.0 18.114063599974315
1790063879.633401 16.66670004556886 0.0 16.66670004556886
```

The test verifies an internal battery, connected external power, decoded voltage/current ranges, increasing timestamps, endpoint direction, and the service's calculations from each same captured reading. These samples support **external supply with zero battery flow**, not active charging, battery-only operation, transitions, or live diagram rendering.

## Image evidence and alpha diagnosis

Raw evidence: [`.build/power-flow-visual-matrix`](../../../.build/power-flow-visual-matrix). All 50 expected files were atomically overwritten by the fresh export, with modification timestamps `2026-09-22 07:58:00 +0000`; native enumeration confirmed exactly 50 PNGs, with no stale additional PNGs. No destructive cleanup was needed.

Diagnostic evidence: [`.build/task8-verification/composites`](../../../.build/task8-verification/composites). Script: [composite.swift](../../../.build/task8-verification/composite.swift); mapping/pixel statistics: [composite-success.log](../../../.build/task8-verification/composite-success.log).

Method: decode the unchanged raw PNGs via ImageIO, draw with Core Graphics source-over onto opaque neutral backgrounds (gray 0.96 for light, 0.12 for dark), encode separate PNGs, and inspect the resulting five sheets. No view rerender, replacement chrome, foreground recoloring, production modification, or raw-image overwrite was used. All raw files were already opened individually before this diagnostic step.

The raw viewer displayed light text/surfaces as black-on-black and dark text/surfaces as white-on-white, often exposing only colored bands and fragments of watt labels. The composites recover complete translucent content. This is an alpha/backdrop viewing issue, **not evidence that translucent labels are missing in the encoded PNGs**.

In contrast, every standard PNG has **one unique RGBA value in its inset interior**, and every standard composite visibly remains an empty rounded card. Changing the backdrop does not recover any label, icon, or flow. Source tracing identifies the macOS 26 `.glassEffect(.regular, in: shape)` branch at `ActiveCleanReleaseLayout.swift:122`; translucent appearance instead uses the existing root-glass policy's ordinary fill at lines 118–120. The pre-existing modifier is unchanged from `77d9536`. This reproduces Task 6's ImageRenderer/native-glass limitation and predates Task 8 infrastructure. It does **not** establish that the live app is blank; live standard rendering remains unverified.

All PNG heights are 208 pixels at 2×, corresponding to 104 points; widths are 768 or 640 pixels. Dimensions corroborate height stability but are not the reason any sample passed visually.

### Fixture-level matrix

`P` = **PASS on inspected neutral composite only**, with raw alpha limitation. `NV` = **NOT_VERIFIED; FAIL evidence because native-glass interior is blank**. `—` = not a planned/exported combination. No P certifies live/varied-desktop rendering.

| Fixture | Standard light 384 | Standard dark 384 | Translucent light 384 | Translucent dark 384 | Standard light 320 | Observed content in viewable composites |
|---|---|---|---|---|---|---|
| 1→1 | NV | NV | P | P | NV | USB-C and Mac separated; continuous neutral/blue flow; full `≈21.46 W`. |
| 1→2 | NV | NV | P | P | NV | One trunk splits into two separated branches; `30.7 W` and `≈26.1 W` readable. |
| 2→1 | NV | NV | P | P | NV | USB-C `20 W` and Battery `24 W` converge; `≈44 W` readable. |
| 2→2 | NV | NV | P | P | NV | Two inputs join visible central shared bus, then two outputs; not four pairwise edges. `45 W`, `12 W`, `30 W`, `≈27 W`, and totals fit. Unknown title ellipsizes. |
| Grouped | NV | NV | P | P | NV | Three sources, two representatives (USB-C 45 W, Battery 12 W), one-more line; two outputs (Battery 30 W, Mac ≈27 W); separate ≥57 W / ≈57 W aggregates. No overlapping regions. |
| Missing source | NV | NV | P | P | NV | Dashed unknown source tile and lane distinguish missing data; solid Mac lane; full `≈24 W` and unavailable-input total. |
| Waiting | NV | NV | P | P | — | Hourglass and waiting message visible in same 104-point card. |
| Idle | NV | NV | P | P | — | Battery icon/title plus idle status; no false active flow; same height. |
| Unavailable | NV | NV | P | P | — | Question-mark symbol, partial-data/status text; same height. |

Baseline fixture titles are English and runtime status/totals are Chinese in this host configuration, as planned by the infrastructure. This is not a claim of fully English baseline localization. German supplemental runtime strings, titles, and comma-formatted values were observed separately.

### Per-file inspection ledger (all 50 raw files opened)

Raw `B` = blank card interior (dark also exposes border). Raw `A` = alpha/backdrop display obscures text; not approved from raw view. Composite `P` and `NV` as above. Each row identifies an actual read-image inspection, not filename-only approval.

| # | PNG filename | Raw | Composite result / observation |
|---:|---|---|---|
| 1 | `01-one-to-one-standard-light-384.png` | B | NV: still blank |
| 2 | `01-one-to-one-standard-dark-384.png` | B | NV: still blank |
| 3 | `01-one-to-one-translucent-light-384.png` | A | P: full ≈21.46 W; separated endpoints |
| 4 | `01-one-to-one-translucent-dark-384.png` | A | P: full value; visible card/tile boundaries |
| 5 | `01-one-to-one-standard-light-320.png` | B | NV: pressure-width content absent |
| 6 | `02-one-to-many-standard-light-384.png` | B | NV: still blank |
| 7 | `02-one-to-many-standard-dark-384.png` | B | NV: still blank |
| 8 | `02-one-to-many-translucent-light-384.png` | A | P: two separated output branches and complete values |
| 9 | `02-one-to-many-translucent-dark-384.png` | A | P: two branches, Battery/Mac icons and values legible |
| 10 | `02-one-to-many-standard-light-320.png` | B | NV: pressure-width content absent |
| 11 | `03-many-to-one-standard-light-384.png` | B | NV: still blank |
| 12 | `03-many-to-one-standard-dark-384.png` | B | NV: still blank |
| 13 | `03-many-to-one-translucent-light-384.png` | A | P: 20 W / 24 W inputs, ≈44 W output |
| 14 | `03-many-to-one-translucent-dark-384.png` | A | P: separated input branches, full values |
| 15 | `03-many-to-one-standard-light-320.png` | B | NV: pressure-width content absent |
| 16 | `04-many-to-many-standard-light-384.png` | B | NV: still blank |
| 17 | `04-many-to-many-standard-dark-384.png` | B | NV: still blank |
| 18 | `04-many-to-many-translucent-light-384.png` | A | P: central shared bus and four branch labels; title ellipsis only |
| 19 | `04-many-to-many-translucent-dark-384.png` | A | P: central bus, two-in/two-out topology and totals legible |
| 20 | `04-many-to-many-standard-light-320.png` | B | NV: pressure-width content absent |
| 21 | `05-grouped-standard-light-384.png` | B | NV: still blank |
| 22 | `05-grouped-standard-dark-384.png` | B | NV: still blank |
| 23 | `05-grouped-translucent-light-384.png` | A | P: counts 3/2, two reps per side, one-more line and aggregates |
| 24 | `05-grouped-translucent-dark-384.png` | A | P: same counts/representatives/more; readable neutral center bus |
| 25 | `05-grouped-standard-light-320.png` | B | NV: grouped pressure-width content absent |
| 26 | `06-missing-source-standard-light-384.png` | B | NV: still blank |
| 27 | `06-missing-source-standard-dark-384.png` | B | NV: still blank |
| 28 | `06-missing-source-translucent-light-384.png` | A | P: dashed synthetic source tile/lane, ≈24 W readable |
| 29 | `06-missing-source-translucent-dark-384.png` | A | P: dashes, unknown icon and unavailable input distinguish missing source |
| 30 | `06-missing-source-standard-light-320.png` | B | NV: pressure-width content absent |
| 31 | `07-waiting-standard-light-384.png` | B | NV: still blank |
| 32 | `07-waiting-standard-dark-384.png` | B | NV: still blank |
| 33 | `07-waiting-translucent-light-384.png` | A | P: hourglass/status, same 104-point height |
| 34 | `07-waiting-translucent-dark-384.png` | A | P: hourglass/status readable, same height |
| 35 | `08-idle-standard-light-384.png` | B | NV: still blank |
| 36 | `08-idle-standard-dark-384.png` | B | NV: still blank |
| 37 | `08-idle-translucent-light-384.png` | A | P: Battery and idle message, no active ribbons |
| 38 | `08-idle-translucent-dark-384.png` | A | P: Battery/idle status readable, same height |
| 39 | `09-unavailable-standard-light-384.png` | B | NV: still blank |
| 40 | `09-unavailable-standard-dark-384.png` | B | NV: still blank |
| 41 | `09-unavailable-translucent-light-384.png` | A | P: question mark, unavailable/partial-data text |
| 42 | `09-unavailable-translucent-dark-384.png` | A | P: question mark/status readable, same height |
| 43 | `supplemental-missing-sink-standard-light-320.png` | B | NV: still blank |
| 44 | `supplemental-missing-sink-standard-dark-320.png` | B | NV: still blank |
| 45 | `supplemental-missing-sink-translucent-light-320.png` | A | P: source 24 W total, unavailable output dash, synthetic dashed sink |
| 46 | `supplemental-missing-sink-translucent-dark-320.png` | A | P: dashed sink/lane visible, source and sink remain separate |
| 47 | `supplemental-long-german-standard-light-320.png` | B | NV: still blank |
| 48 | `supplemental-long-german-standard-dark-320.png` | B | NV: still blank |
| 49 | `supplemental-long-german-translucent-light-320.png` | A | P: `≈21,46 W` and `Ein — · Aus ≈21,46 W` fully readable; title/status ellipsize |
| 50 | `supplemental-long-german-translucent-dark-320.png` | A | P: same complete watt values, dashed unavailable input, readable contrast |

German `Mehrere Energiefl...`, `Unvollständige...`, and `Unbeka...` truncations are observed, not hidden. Truncatable title/status text is an intentional view contract; watts/totals are not truncated. Hover help exists in source but was not exercised live. No supplemental image substitutes for a missing baseline combination.

## Live application, accessibility, and hardware states

Read-only native environment probing found screen-capture authorization **true**, accessibility trust **true**, and Reduce Motion / Reduce Transparency / Increase Contrast / Differentiate Without Color all **false**. Permissions were not requested or changed.

The currently running app (PID 70495) was from `/Users/how/Library/Developer/Xcode/DerivedData/MacActivity-fsmequkgsbygozccmrklhmwwhbhq/Build/Products/Debug/Mac Activity.app`, not the verified build at `MacActivity-dsrrtvxcuiipeaeuhxvgogfmrxre`. Its AX window query succeeded with an empty window list. It was neither treated as branch evidence nor terminated.

**The newly built app was not launched.** A second instance would share the user's app preferences; `AppDelegate.swift:166–167` can reconcile launch-at-login state at startup. No isolated no-state-change launch was established. This is a deliberate verification gap, not a permissions failure or an assertion that GUI testing is impossible. No screenshot or AX-tree inspection of the changed app was obtained.

| Required live condition | Status | Observation / reason |
|---|---|---|
| Light + standard | NOT_RUN | Changed app not launched/observed; ImageRenderer standard output cannot substitute for native glass. |
| Dark + standard | NOT_RUN | Same limitation; no live contrast or nested-glass judgment. |
| Light + translucent | NOT_RUN | Neutral composite is readable, but no varied-desktop live observation. |
| Dark + translucent | NOT_RUN | Neutral composite boundaries are visible; live tile-opacity behavior not observed. |
| Increase Contrast | NOT_RUN | Workspace setting false; no preference toggle. Policy tests/source are not live evidence. |
| Reduce Transparency | NOT_RUN | Workspace setting false; fallback surface not observed live. |
| Reduce Motion | NOT_RUN | Workspace setting false; no live topology transition observation. |
| Differentiate Without Color | NOT_RUN | Workspace setting false; fixture icons/dashes do not certify live setting behavior. |
| Inactive window | NOT_RUN | No changed-app active/inactive window observation. |
| External power directly supplying Mac | PASS for native telemetry; NOT_RUN for live UI | Three native samples show input = Mac watts and battery 0 W; no application screenshot. |
| Active battery charging | NOT_RUN | Battery flow was 0 W in all samples; charging state was not induced. |
| Battery-only operation | NOT_RUN | External power was connected; no cable/power-state change. |
| Rapid connect/disconnect | NOT_RUN | Would require changing hardware power state; not performed. |
| Sensor-unavailable behavior | NOT_RUN | Sensors returned usable readings; no artificial live sensor failure induced. Fixture coverage only. |

VoiceOver narration/tree behavior and hover-help recovery were also NOT_RUN for the changed app. Static source modifiers and image observations are not accessibility runtime approval.

## Supporting command audit and failures

The detailed local report is `.superpowers/sdd/2026-09-22-power-flow-diagram/task-8-validation-report.md`. Supporting terminal actions (in addition to every required command tabulated above):

| Command/action | Result | Attribution / cause |
|---|---|---|
| `pwd`; `git branch --show-current`; `git rev-parse HEAD`; `date '+%Y-%m-%d %H:%M:%S %Z'`; `git status --short` | Exit 0; expected workdir/branch/head/date; initially clean | Identity established independently at 17:55:54 AEST. |
| `ls .build`; `ls docs/superpowers`; `ls .superpowers/sdd/2026-09-22-power-flow-diagram`; later `ls .build/task8-verification` and `ls docs/superpowers/verification` | Exit 0 | Verified parents before creating artifacts/docs. |
| `mkdir -p .build/task8-verification`; `mkdir -p docs/superpowers/verification` | Exit 0 | Created only evidence/document directories. |
| `sw_vers`; `xcodebuild -version`; `swift --version`; `xcodegen --version` | Exit 0 | Versions recorded above. |
| Initial `apply_patch` command | Exit 127 | Environment/tooling failure: `zsh:1: command not found: apply_patch`; no files changed by failed patch. |
| Initial `swift .build/task8-verification/composite.swift .build/power-flow-visual-matrix .build/task8-verification/composites` | Exit 1; real/user/sys 0.07 / 0.04 / 0.02 | Consequence of absent patch executable: `error opening input file '.build/task8-verification/composite.swift' (No such file or directory)`. Not a product failure. Preserved in `composite.log`. |
| `command -v apply_patch`; `command -v patch`; `command -v python3`; `ls /var/folders/lx/sc42h4m17l905svhlfzj8p380000gn/T/opencode` | apply_patch exit 1; other commands exit 0 | Native patch at `/usr/bin/patch`; Python shim at `/Users/how/.pyenv/shims/python3`. No apply_patch executable found. |
| Add-file-only `apply_patch` compatibility shell function, then patch for ignored diagnostic Swift script | Exit 0 | Local Python stdlib shim accepts `*** Add File` only and refuses existing files. Tool adaptation, not product change. |
| Repeated native composite command after script creation | Exit 0; real/user/sys 0.92 / 0.70 / 0.10 | 50 original files decoded/composited; 50 individual derivatives + five sheets. Preserved separately in `composite-success.log`. |
| Read-only `swift -e` workspace/permission probe | Exit 0 | Actual authorization and accessibility settings recorded above. |
| Read-only `swift -e` running-app path and AX windows query | Exit 0 | Identified unrelated running build; AX query code 0, empty windows. |
| `git log --oneline -12`; `git log -1 --format='%h %s' -- Sources/MacActivityApp/Views/ActiveCleanReleaseLayout.swift Sources/MacActivityApp/AppShell/DashboardPanelSupport.swift` | Exit 0 | Latest change to these pre-existing files was `77d9536`. |
| Later `git status --short`; `git diff --check`; repeated parent `ls` commands | Exit 0 | Still clean before documentation. A final `command -v apply_patch` returned 1, showing shell functions do not persist across tool calls. |
| `git diff --exit-code 77d9536..HEAD -- Sources/MacActivityApp/Views/ActiveCleanReleaseLayout.swift Sources/MacActivityApp/AppShell/DashboardPanelSupport.swift Tests/MacActivityAppTests/DashboardPopoverControllerTests.swift Tests/MacActivityCoreTests/EnergyImpactNativeValidationTests.swift` | Exit 0, no output | Confirms chrome, non-Sendable warning source, and unrelated skip sources are unchanged from baseline. |
| Pre-ledger `git diff --check`; `date '+%Y-%m-%d %H:%M:%S %Z'` | Exit 0 | No whitespace errors; 2026-09-22 18:04:05 AEST. |

Read/glob/search tools were also used. Two initial reads failed because this worktree has no `AGENTS.md` and the native test is in `MacActivityCoreTests`, not `MacActivityAppTests`; the correct native test was subsequently located/read. Searching absent `.opencode` failed, and `/tmp/repo_support` was absent while checking for an installed patch helper. These are discovery/tooling misses, not branch failures. Parent repository AGENTS instructions supplied in the session were followed.

No broader testing was repeated after the required checks passed. The subsequent work was the specifically requested image diagnosis and read-only environment/source attribution. Artifacts under `.build` are ignored and local, not durable CI attachments; preserve them if handing off this ledger.

### Post-write audit (18:09:42 AEST)

`git diff --check` exited 0. `git diff --exit-code -- Sources Tests MacActivity.xcodeproj/project.pbxproj` exited 0 with no changes. `git status --short` exited 0 and showed only `?? docs/superpowers/verification/`; the local report and build artifacts are ignored. `git rev-parse HEAD` exited 0 and remained the literal HEAD above. `date '+%Y-%m-%d %H:%M:%S %Z'` exited 0 with `2026-09-22 18:09:42 AEST`.

Both `git diff --no-index --check /dev/null <new-report-path>` commands returned **1**, with **no whitespace diagnostics** (one for this ledger, one for the local validation report). The no-index new-file comparison reports differences; this is not a test/build failure, and the nonzero codes are preserved rather than rewritten as 0. Report creation used the documented add-file compatibility function; this audit was appended with a local `apply_patch` function delegating unified patches to `/usr/bin/patch`, without touching product files.

## Documentation follow-up: package import and branch whitespace

The tested HEAD at the top of this record remains the implementation revision to which the automated and visual results apply. This follow-up changes documentation only; it does not advance the spec to implemented/verified or establish full acceptance. The 22 conditional translucent composite passes, 28 blank/unverified standard samples, and unrun live matrix remain unchanged.

`git diff --check next-version...HEAD` subsequently exposed ten inherited Markdown hard-break trailing-space lines in the imported design spec (original lines 3–6, 763, 768, 773, 778, 783, and 788). The earlier plain `git diff --check` results checked working-tree changes, not the accumulated branch diff; they did not establish branch-wide whitespace cleanliness. The hard breaks were replaced with blank paragraph separators, without substantive design changes.

Comparison with the approved planning package's extracted spec at `/var/folders/lx/sc42h4m17l905svhlfzj8p380000gn/T/opencode/mac-activity-power-flow-planning/docs/superpowers/specs/2026-09-22-power-flow-diagram-design.md` using `git diff --no-index` showed exactly one pre-correction difference: the branch said `Draft for user review`, while the approved package said `Approved for implementation planning`. The approved status was restored as a package-import correction, not a verification-status advancement.

`gh pr view feat/power-flow-diagram` returned `no pull requests found for branch "feat/power-flow-diagram"`. PR metadata readiness is **not applicable**: there is no PR to assess, and no PR was created. Full tests/builds were not rerun for this documentation-only correction.

After correction, `git diff --check` and `git diff --check next-version` both exited 0 with no diagnostics (the latter includes the pending spec correction against the base branch). `git diff --exit-code -- Sources Tests MacActivity.xcodeproj/project.pbxproj` also exited 0 with no changes. Only this verification record and the design spec are included in the supplemental documentation commit.
