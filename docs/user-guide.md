# User Guide

MacActivity is a lightweight macOS menu bar utility for live system metrics,
quick cleanup actions, and Sparkle-based app updates. It runs as an accessory
app and opens a compact dashboard from the menu bar.

## Requirements

- macOS 13.0 or newer.
- A Mac that exposes the requested hardware metrics. Some temperature, fan,
  battery, GPU, and VRAM readings depend on hardware and system APIs.

## Opening MacActivity

Launch the app from Finder, Spotlight, a release artifact, or Xcode. When the
menu bar item is visible, click it to open the dashboard popover.

MacActivity is an accessory app. If the menu bar item is hidden or unavailable,
reopen the app and use Preferences to restore the menu bar item.

## Dashboard

The dashboard summarizes current system activity and shows trend views when
history is available.

Current metric surfaces:

- CPU usage.
- GPU usage, when available.
- Disk usage for the current user's volume.
- Swap usage.
- Memory usage, pressure, and breakdown history.
- VRAM usage, when available.
- Network upload and download throughput.
- Battery percentage and charging state.
- Temperature from the selected source, when available.
- Fan speed, when available.

Disk and swap cards use percent bars and history when the provider has samples.
Network trends need at least two samples before the direction is meaningful.
Temperature, fan, GPU, VRAM, and battery metrics can be unavailable on Macs that
do not expose the relevant source.

## Actives

The Actives surface focuses on cleanup work and process memory.

- Disk Cleanup scans the selected categories and reports clean, cleanable,
  cleaned, partial, or failed states.
- The process list shows the top memory-using applications.
- Rows show app icons when the bundle is available and fall back to a system app
  symbol when not.
- Hover a process row to show the Quit action.
- Clicking Quit once asks for confirmation; the confirmation times out after
  about three seconds.
- Preferences can hide bundle identifiers or fallback process identifiers in the
  process list.

The process list is based on currently running applications and can change as
apps launch, quit, or reject termination.

## Preferences

Open Preferences from the app controls.

Available preferences:

- Launch at login.
- Display language.
- Temperature source: CPU/SMC or Battery.
- Hardware battery percentage, when raw AppleSmartBattery capacity is exposed.
- Show or hide application identifiers in Actives process rows.
- Disk cleanup categories.
- Menu bar summary metrics.
- Update channel and Check for Updates.

The menu bar summary order is fixed:

```text
CPU -> GPU -> Disk -> Swap -> Memory -> VRAM -> Temperature -> Fan -> Network -> Battery
```

The default summary selection is CPU, GPU, Memory, VRAM, Temperature, Fan, and
Network. Disk, Swap, and Battery can be enabled from Preferences.

The update channel control is collapsed beside the current version by default.
Expand it to choose:

- `release`: only final releases.
- `beta`: beta and release updates.
- `alpha`: alpha, beta, and release updates.

MacActivity prefers the highest eligible channel. For example, an alpha-channel
install can still update to a newer beta or final release.

## Cleanup Features

MacActivity has cleanup surfaces for memory, Trash, and selected disk cleanup
categories.

Memory Release:

- Reads current memory before and after cleanup.
- Attempts the local cleanup strategy first.
- Falls back to the system `purge` path when local cleanup is unavailable or not
  significant.
- Uses a short cooldown to avoid repeated cleanup clicks.

Trash cleanup:

- Scans the current user's `~/.Trash`.
- Deletes confirmed Trash contents.
- Reports partial cleanup if some items cannot be removed.

Disk Cleanup categories:

- User Caches: files under `~/Library/Caches`, excluding Apple and sensitive
  cache paths, and only when old enough.
- Trash: current user's `~/.Trash`.
- User Logs: log-like files under `~/Library/Logs`.

The default Disk Cleanup category is User Caches. Trash and User Logs are
optional preferences.

## Metric Availability

Some metrics are intentionally conditional:

- Temperature can come from CPU/SMC or Battery, depending on the selected source
  and hardware support.
- Fan, GPU, and VRAM readings may be absent on some Macs.
- Hardware battery percentage falls back to the system percentage when raw
  AppleSmartBattery capacity is not available.
- Disk and swap samples run on a slower cadence than CPU or network samples.
- Memory history improves after the app has been running long enough to collect
  samples.

## Troubleshooting

If the dashboard appears stale, wait for the next sampling cycle and reopen the
popover. If a metric remains unavailable, check whether that metric depends on a
hardware sensor that your Mac does not expose.

If launch at login does not behave as expected, toggle the preference off and on
again, then log out and back in.

If cleanup deletes less than expected, check the selected cleanup scope and file
permissions. Some files may be locked, still in use, too new for cache cleanup,
or protected by permissions.

For reproducible issues, see [SUPPORT.md](/docs/SUPPORT.md).
