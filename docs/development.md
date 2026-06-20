# Development Guide

This guide covers local development for MacActivity.

## Repository Layout

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

The package declares Swift tools version 6.2. Use the Xcode toolchain selected
by `xcode-select` unless a task explicitly needs another toolchain.

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

Run the SwiftPM tests:

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

## Architecture Notes

`MacActivityCore` owns behavior that should be testable without the app shell:
metric snapshots, history, providers, cleanup services, scheduling, formatting,
preferences state, and presentation models.

`MacActivityApp` owns the macOS app shell: status item rendering, dashboard
popover hosting, preferences window coordination, localization, and SwiftUI
views.

Prefer putting logic in `MacActivityCore` when it can be expressed without
AppKit or SwiftUI. Keep app-shell code focused on lifecycle, presentation, and
macOS integration.

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

- User-visible app behavior: update [user-guide.md](user-guide.md).
- Build, test, architecture, localization, or tooling changes: update this file.
- Release workflow, versioning, artifact, or release-note behavior: update
  [release.md](release.md).
- PR policy or review requirements: update [CONTRIBUTING.md](CONTRIBUTING.md).

Keep generated planning notes and temporary scratch files out of this repository
unless they are intentionally promoted into `docs/`.
