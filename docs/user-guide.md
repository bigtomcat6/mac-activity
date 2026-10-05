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
menu bar item is visible, click it to open the dashboard. On macOS 26 the
dashboard floats under the menu bar as a Liquid Glass panel with clear glass
modules, like Control Center, and follows the system light or dark appearance. With Reduce
Transparency turned on, on earlier macOS versions, or when the menu bar item is
not in the menu bar, it opens as a standard popover instead.

MacActivity is an accessory app. If the menu bar item is hidden or unavailable,
reopen the app and use Preferences to restore the menu bar item.

## Dashboard

The dashboard summarizes current system activity and shows trend views when
history is available.

The dashboard stays compact when application lists are long. On Energy, scroll
the application rows while the power summary and column header stay in place.
Actives keeps disk cleanup and process-action messages outside the scrolling
application rows. Audio's output-device and application lists scroll independently;
short lists use only the space they need. If the available window is too short
for those fixed sections, the page scrolls as a whole instead. Overview retains
its whole-page scrolling.

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

The Energy Impact page shows a physical power-flow panel above the app ranking:

- Physical power flow shows active input and output endpoints above the app energy-impact ranking.
- Battery appears as an input while discharging and an output while charging.
- Connector labels can identify USB-C or MagSafe when Mac Activity can recognize the adapter; otherwise the app shows an unknown external interface.
- Input watts come directly from current SMC input voltage and current readings. Battery watts come directly from current SMC battery voltage and signed-current readings.
- If a live SMC sensor is unavailable, its related flow remains unavailable. Mac Activity does not substitute adapter ratings, negotiated limits, or a cached earlier reading.
- The Mac value is a derived allocation: external input plus battery discharge minus battery charging. It includes the non-battery residual in that flow and is not an independently measured system-load sensor.
- The panel keeps its active input/output endpoint layout and uses mW for sub-watt readings.
- App energy-impact CPU estimates are separate process estimates and are not inputs to physical power flow.
- These readings do not claim exact AlDente parity for charging states that have not been validated.

## Audio

Output-device sliders apply volume changes while you drag, rather than waiting
for you to release the slider. Sliders are available when the device exposes
writable volume and mute controls. Dragging to zero mutes the device; dragging
up restores audible output at the selected volume.

Application audio controls require macOS 14.2 or later and system audio capture
permission. MacActivity silently checks the current status when the Audio page
opens or becomes active; this check does not request permission. Until access
is available, the application region is replaced by a recording-permission view
with a `record.circle` icon while output-device controls remain available.
Choose **Grant Access** before macOS has made a decision. If access was denied,
the action opens System Settings instead of repeatedly requesting permission.
The manual **Grant Access** button is the only place MacActivity uses the
private `TCCAccessRequest` callback. When macOS allows access, the application
list updates immediately; restarting MacActivity is not required. Page entry,
focus changes, and service restarts continue to use only the silent status
check and never request permission.

The silent status check and the manual callback use macOS private TCC
interfaces. Apple may change or remove either interface in a future macOS
release; if one is unavailable, MacActivity shows an honest unavailable state
rather than application controls. No system-audio recording request is made
until you choose **Grant Access**.

The application list includes processes currently producing audio output and
excludes MacActivity's own process. Each application row shows its localized
application name and icon when its bundle can be resolved. If no applications
are playing audio after access is available, the page shows that empty state;
it does not indicate whether permission was granted.

Changing an application's output can briefly show a rebuilding state while the
previous route's audio resources are released. A newer selection replaces a
pending selection. If cleanup cannot complete or the route is unavailable, the
control reports a failure; use Retry after the underlying problem is resolved.
Device and route compatibility still depend on the hardware and macOS APIs.

## Audio

Output-device sliders apply volume changes while you drag, rather than waiting
for you to release the slider. Sliders are available when the device exposes
writable volume and mute controls. Dragging to zero mutes the device; dragging
up restores audible output at the selected volume.

Application audio controls require macOS 14.2 or later and system audio capture
permission. MacActivity silently checks the current status when the Audio page
opens or becomes active; this check does not request permission. Until access
is available, the application region is replaced by a recording-permission view
with a `record.circle` icon while output-device controls remain available.
Choose **Grant Access** before macOS has made a decision. If access was denied,
the action opens System Settings instead of repeatedly requesting permission.
The manual **Grant Access** button is the only place MacActivity uses the
private `TCCAccessRequest` callback. When macOS allows access, the application
list updates immediately; restarting MacActivity is not required. Page entry,
focus changes, and service restarts continue to use only the silent status
check and never request permission.

The silent status check and the manual callback use macOS private TCC
interfaces. Apple may change or remove either interface in a future macOS
release; if one is unavailable, MacActivity shows an honest unavailable state
rather than application controls. No system-audio recording request is made
until you choose **Grant Access**.

The application list includes processes currently producing audio output and
excludes MacActivity's own process. Each application row shows its localized
application name and icon when its bundle can be resolved. If no applications
are playing audio after access is available, the page shows that empty state;
it does not indicate whether permission was granted.

Changing an application's output can briefly show a rebuilding state while the
previous route's audio resources are released. A newer selection replaces a
pending selection. If cleanup cannot complete or the route is unavailable, the
control reports a failure; use Retry after the underlying problem is resolved.
Device and route compatibility still depend on the hardware and macOS APIs.

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

MacActivity can clean selected disk cleanup categories from the Actives page,
after a confirmation click.

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
- Connector labels and direct power-flow values depend on hardware and system
  APIs, and unavailable values are expected on some Macs. A Mac without an
  internal battery has no battery endpoint; a present battery with unavailable
  live SMC telemetry leaves its related allocation unavailable.

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
