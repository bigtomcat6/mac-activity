# Development Guide

This guide covers local development for MacActivity.

## Repository Layout

The repository root contains the SwiftPM package, generated Xcode project,
automation, and documentation.

```text
.
├── Configuration/             # xcconfig, Info.plist, entitlements
├── Sources/
│   ├── MacActivityApp/        # SwiftUI/AppKit app, popover, preferences, views
│   ├── MacActivityCore/       # metrics, cleanup, scheduling, preferences
│   └── MacActivityBatteryControl/ # Foundation-only battery semantics/policy/session
├── Tests/
│   ├── MacActivityAppTests/
│   ├── MacActivityCoreTests/
│   └── MacActivityBatteryControlTests/
├── Tools/                     # debug executables for focused local checks
├── scripts/                   # local install/build helpers
├── .github/                   # workflows, PR template, release scripts
└── docs/                      # canonical project documentation
```

## Requirements

- macOS 26.0 or newer on a Mac with Apple silicon.
- Xcode 26 or newer with the Swift 6.2 toolchain.
- XcodeGen 2.45.0 or newer; CI pins 2.45.4. Local 2.45.3 repeat-generation
  determinism does not establish byte equality with that CI version.

`Package.swift` declares Swift tools version 6.2 and depends on Sparkle from
version 2.9.3.

## Clone

```bash
git clone https://github.com/bigtomcat6/mac-activity.git
cd mac-activity
```

## Xcode Workflow

Regenerate the project after changing `project.yml` or adding source/test files:

```bash
xcodegen generate
```

Open and run the `MacActivity` scheme:

```bash
open MacActivity.xcodeproj
```

Run app, core, and battery-control tests from Xcode with the `MacActivity`
scheme. Generated project/scheme files must come from XcodeGen, never hand edits.

## SwiftPM Workflow

Run SwiftPM tests:

```bash
swift test
```

If the local sandbox or module cache causes compiler cache issues, retry with an
explicit cache path:

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test
```

## Xcodebuild Tests

Use Xcodebuild when validating the generated Xcode project, app-hosted tests, or
workflow parity:

```bash
xcodebuild test \
  -project MacActivity.xcodeproj \
  -scheme MacActivity \
  -destination 'platform=macOS'
```

## Focused Debug Tools

The project includes focused executables and command wrappers for local checks:

- `DebugActiveProcessMemory`
- `DebugDiskCleanup`
- `scripts/debug-active-process-memory.command`
- `scripts/debug-disk-cleanup.command`

Use these for narrow cleanup or Actives checks before broad app validation.

Tool files named `main.swift` use top-level entry calls, not `@main`, so they
do not depend on SwiftPM's inferred `-parse-as-library` flag in Xcode.
Async entry calls use `await` and preserve `@MainActor` on the entry method.
`ToolEntrypointTests` checks this convention across `Tools`, including nested packages.

## Architecture Notes

`MacActivityCore` owns behavior that should be testable without the app shell:
metric snapshots, history, providers, cleanup services, scheduling, formatting,
preferences state, update selection, and presentation models.

`MacActivityApp` owns the macOS app shell: status item rendering, dashboard
hosting (a clear floating panel on macOS 26, a popover under Reduce Transparency
or on earlier systems), preferences window coordination, localization, Sparkle
updater integration, and SwiftUI views.

Prefer putting logic in `MacActivityCore` when it can be expressed without
AppKit or SwiftUI. Keep app-shell code focused on lifecycle, presentation, and
macOS integration.

## Battery Care implementation boundary

Battery Care is currently an **A-stage, no-hardware foundation**, not an enabled
charging feature. `AppDelegate.startBatteryCare` composes one `BatteryCareModel`
with `UnavailableBatteryCareService`, shared by the dashboard and sleep/wake/quit
bridge. No executable backend is assembled in production. Default settings are
disabled/80%; no UI flag, saved enabled preference, readable SMC key, or Apple
silicon model name grants hardware capability. Minimum platform remains macOS 26,
arm64, not a promise of all-device support.

`MacActivityBatteryControl` is a small Foundation-only shared module containing
validated settings/value types, the pure `BatteryCarePolicy`, and the serialized
in-process `BatteryCareSession`. It must not import AppKit, IOKit, Security,
ServiceManagement, or Sparkle. Preferences persist only regular enabled/limit
intent, not previews, temporary modes, admission, or recovery evidence. The App
model owns save/accept ordering and stale snapshot isolation; Session owns write
serialization, independent input ticks, and unresolved-apply responsibility.
Reading snapshots or refreshing display metrics does not drive the watchdog.
There is no production control sampler/timer or certified timing default.

The small `Tests/MacActivityAppTests/BatteryCareIntegrationTests.swift` smoke
suite goes through **real Model → real Session → real Policy → test-local backend**,
using a real `PreferencesController` with memory-only storage. The backend supplies
synthetic observations/receipts and continuation gates, never policy. It covers
one committed limit, full-charge exit before a new regular target, and the actual
App's unavailable composition. Release confirmation is awaited separately from
`send` completion; after release the test explicitly supplies the existing internal
tick to re-evaluate regular policy. The synthetic timing values are not device
budgets. No real battery discharge, including to 20%, is performed.

For a focused logic check (using already available dependencies):

```bash
swift test --filter BatteryCareIntegrationTests
```

Keep A4 write-isolation/deadline tests and A5 late-snapshot/persistence tests at
their existing layers; do not duplicate their matrices here. A scoped pass is not
a full SwiftPM or Xcode result. App-hosted Xcode tests launch a host; audit and
authorize that execution separately. For restricted no-hardware validation, use
locked cached dependencies and memory stores; do not run old UserDefaults-writing
tests against user settings. Native/visual tests need their documented environment
and opt-ins, not weaker assertions or new skips.

**Validation status and remaining gates:** A7's original native/wheel failures and
live-animation skips were rerun and passed in an active, unlocked display session.
The latest scoped UI/battery validation had no failures and one existing OS Reduce
Motion skip; it is not a full-suite result. No-host BatteryControl Xcode tests and
unsigned Release compile/link also passed, but app-hosted tests remain unrun
because a safe test-host entry point is still missing. The known EnergyImpact
live-catalog empty-name defect remains unresolved, SwiftLint is not green, and
manual VoiceOver validation remains outstanding. A-stage completion and release
readiness are not established; G/B hardware enablement remains deferred.

Hardware/system capability, full-charge evidence, physical stopping bounds, and
helper trust/distribution require G admission and approved B0 follow-up. Wire
codec, client authentication, control ownership/baseline/journal, persistent
recovery, and a real backend are deferred **with their corresponding safety tests**;
they are not implemented or validated by A-stage tests. No SMC key/value or helper
installation recipe is supplied here. The approved future rules (five-point
hysteresis, regular 100% handing back to macOS, one-shot discharge, changed-limit
full-charge cancellation, lifecycle release requests) are not production support.
The 20% fallback is not a safety certification or a substitute for bounded stop
evidence. Intent/acceptance/readback/physical effect and unknown recovery remain
distinct. Control uses verified system percentage; chart hardware-percentage
preferences and display sampling never change that control basis.

## Metrics

Metric kinds currently include CPU, GPU, Disk, Swap, Memory, VRAM, Network,
Battery, Temperature, and Fan.

Sampling profiles tune cadence by app state:

- `realtime`: provider defaults.
- `balanced`: normal foreground sampling.
- `background`: slower memory, disk, swap, VRAM, temperature, and fan updates.
- `energySaver`: slowest nonessential sampling while keeping fast CPU and
  network updates.

## Localization

Localization keys are centralized by `AppLocalization.Key` and backed by
localized string files under `Sources/MacActivityApp/Resources/`.

When adding user-visible text:

1. Add or reuse an `AppLocalization.Key`.
2. Update `en.lproj/Localizable.strings`.
3. Update `zh-Hans.lproj/Localizable.strings`.
4. Add or update localization tests when the change affects key coverage,
   placeholder parity, or language selection behavior.

## Documentation Updates

Update documentation in the same pull request as the behavior change:

- User-visible app behavior: update [user-guide.md](/docs/user-guide.md).
- Build, test, architecture, localization, or tooling changes: update this file.
- Release workflow, versioning, artifact, updater, or release-note behavior:
  update [release.md](/docs/release.md).
- PR policy or review requirements: update [CONTRIBUTING.md](/docs/CONTRIBUTING.md).

Keep project docs under `docs/`. Do not add nested docs directories such as
`docs/mac-activity`.
