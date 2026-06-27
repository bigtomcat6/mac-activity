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
│   └── MacActivityCore/       # metrics, cleanup, scheduling, preferences
├── Tests/
│   ├── MacActivityAppTests/
│   └── MacActivityCoreTests/
├── Tools/                     # debug executables for focused local checks
├── scripts/                   # local install/build helpers
├── .github/                   # workflows, PR template, release scripts
└── docs/                      # canonical project documentation
```

## Requirements

- macOS 13.0 or newer.
- Xcode 16 or newer with a Swift 6 toolchain.
- XcodeGen, when regenerating `MacActivity.xcodeproj` from `project.yml`.

`Package.swift` declares Swift tools version 6.2 and depends on Sparkle from
version 2.9.3.

## Clone

```bash
git clone https://github.com/bigtomcat6/mac-activity.git
cd mac-activity
```

## Xcode Workflow

Regenerate the project after changing `project.yml`:

```bash
xcodegen generate
```

Open and run the `MacActivity` scheme:

```bash
open MacActivity.xcodeproj
```

Run app and core tests from Xcode with the `MacActivity` scheme.

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

- `DebugMemoryRelease`
- `DebugActiveProcessMemory`
- `DebugMemoryReleaseUI`
- `DebugDiskCleanup`
- `scripts/debug-memory-release.command`
- `scripts/debug-active-process-memory.command`
- `scripts/debug-memory-release-ui.command`
- `scripts/debug-disk-cleanup.command`

Use these for narrow cleanup or Actives checks before broad app validation.

## Architecture Notes

`MacActivityCore` owns behavior that should be testable without the app shell:
metric snapshots, history, providers, cleanup services, scheduling, formatting,
preferences state, update selection, and presentation models.

`MacActivityApp` owns the macOS app shell: status item rendering, dashboard
popover hosting, preferences window coordination, localization, Sparkle updater
integration, and SwiftUI views.

Prefer putting logic in `MacActivityCore` when it can be expressed without
AppKit or SwiftUI. Keep app-shell code focused on lifecycle, presentation, and
macOS integration.

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
