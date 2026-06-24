# Mac Activity

[![CI](https://github.com/bigtomcat6/mac-activity/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/bigtomcat6/mac-activity/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/bigtomcat6/mac-activity/branch/main/graph/badge.svg)](https://codecov.io/gh/bigtomcat6/mac-activity)
[![Release](https://img.shields.io/github/v/release/bigtomcat6/mac-activity?include_prereleases&sort=semver)](https://github.com/bigtomcat6/mac-activity/releases)
[![License](https://img.shields.io/github/license/bigtomcat6/mac-activity)](./LICENSE)
![macOS](https://img.shields.io/badge/macOS-13.0%2B-000000?logo=apple&logoColor=white)

Mac Activity is a lightweight macOS menu bar utility that shows live system metrics and opens a compact dashboard for deeper inspection.

It ships as:
- `MacActivityApp`: the macOS app that renders the menu bar item and popover dashboard.
- `MacActivityCore`: a reusable framework containing metric providers, sampling logic, preferences state, and data formatting.

## Features

- Menu bar summary with configurable metrics.
- Live popover dashboard with metric cards.
- Basic network trend visualization (download/upload sparkline).
- Customizable menu bar metrics and launch behavior.
- Launch at login toggle.
- Per-metric sampling cadence (`fast`, `medium`, `slow`) and history tracking.
- Unit tests for core scheduling, summary formatting, preferences, snapshot/history, and dashboard model behavior.

## Supported metrics

Implemented providers:
- CPU usage
- Memory usage
- Network throughput (upload/download rates)
- Battery percentage + charging status
- Temperature *(MVP placeholder currently unavailable on many systems)*
- Fan speed *(MVP placeholder currently unavailable on many systems)*

## Requirements

- macOS 13.0+
- Xcode 16 (recommended) with Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (only needed if you want to regenerate `MacActivity.xcodeproj` from `project.yml`)

## Getting started

```bash
git clone https://github.com/bigtomcat6/mac-activity.git
cd MacActivity/mac-activity
```

### Build in Xcode

1. Generate the Xcode project if you changed `project.yml`:

```bash
xcodegen generate
```

2. Open the project and run the `MacActivity` scheme.

```bash
open MacActivity.xcodeproj
```

### Build / test with SwiftPM

```bash
swift test
```

> If `swift test` fails due to your local Xcode/Swift setup, use Xcode and run the `MacActivity` test scheme.

## Runtime behavior

- App launches as an accessory app with a menu bar item by default.
- Clicking the menu bar item opens the dashboard popover.
- You can disable the menu bar item in Preferences; the app remains reachable until you re-enable it.
- When launched with menu bar hidden, the app can still be recovered from the preferences flow.

## Configuration

Open Preferences and you can:

- Toggle **Show menu bar item**
- Toggle **Launch at login**
- Choose which summary metrics appear in the menu bar

Metric order is stable (CPU → Memory → Network → Battery → Temperature → Fan), while some metrics may be hidden when not available on the current machine.

## Architecture

The codebase is split into two targets:

- `Sources/MacActivityCore`
  - metric snapshot/history model
  - provider protocol and provider implementations
  - scheduler and cadence control
  - formatters and presentation models
  - persistence for user preferences
- `Sources/MacActivityApp`
  - status item rendering
  - popover/dashboard UI
  - app lifecycle and activation handling
  - preference window and launch-at-login integration

## Contributing

Contributions are welcome.

- Open an issue describing the problem/idea.
- Include steps to reproduce for bug fixes.
- Keep changes scoped and include/update tests for behavior changes.
- For substantial changes, prefer small incremental PRs.

## License

Licensed under the [Apache License 2.0](./LICENSE).
