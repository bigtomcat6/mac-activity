# User Guide

MacActivity is a lightweight macOS menu bar utility for live system metrics and
quick cleanup actions. It runs as an accessory app and opens a compact dashboard
from the menu bar.

## Requirements

- macOS 13.0 or newer.
- A Mac that exposes the requested hardware metrics. Some temperature, fan, or
  battery readings depend on hardware and system APIs.

## Opening MacActivity

Launch the app normally from Finder, Spotlight, or Xcode. When the menu bar item
is visible, click it to open the dashboard popover.

If the menu bar item is hidden in Preferences, the app remains running as an
accessory app. Reopen the app or return to Preferences to enable the menu bar
item again.

## Dashboard

The dashboard summarizes current system activity and provides trend views where
history is available.

Primary metric surfaces:

- CPU usage.
- Memory usage and pressure.
- Network upload and download throughput.
- Battery percentage and charging state.
- Disk activity or cleanup status where available.
- Temperature, when a supported source is available.
- Fan speed, when a supported source is available.

The dashboard also includes an Actives surface for app memory and cleanup work.
Availability can vary by machine and macOS permission state.

## Preferences

Open Preferences from the app menu or dashboard controls.

Available preferences include:

- Show or hide the menu bar item.
- Launch at login.
- Choose the display language.
- Choose the temperature source when multiple sources are available.
- Show hardware battery percentage when raw AppleSmartBattery capacity is
  available.
- Choose the disk cleanup scope used by Actives Disk Cleanup.

## Cleanup Features

MacActivity has cleanup surfaces for memory, Trash, and selected disk cleanup
categories.

- Memory Release attempts to release reclaimable system memory when a supported
  method is available.
- Trash cleanup checks the current user's Trash and deletes confirmed Trash
  contents.
- Disk Cleanup scans the selected categories, such as caches, Trash, and logs,
  then deletes selected cleanup files.

Cleanup actions should report whether nothing was found, cleanup succeeded,
cleanup partially succeeded, or cleanup failed. If a cleanup action fails, retry
after checking file permissions and whether another process is using the files.

## Metric Availability

Some metrics are intentionally conditional:

- Temperature and fan readings may be unavailable on some Macs or macOS versions.
- Hardware battery percentage falls back to the system percentage when raw
  AppleSmartBattery capacity is not available.
- Network rates need at least two samples before a trend is meaningful.
- Memory history improves after the app has been running long enough to collect
  samples.

## Troubleshooting

If the dashboard appears stale, wait for the next sampling cycle and reopen the
popover. If a metric remains unavailable, check whether that metric depends on a
hardware sensor that your Mac does not expose.

If launch at login does not behave as expected, toggle the preference off and on,
then log out and back in.

If cleanup deletes less than expected, check the selected cleanup scope and file
permissions. Some files may be locked or in use by another process.

For reproducible issues, see [SUPPORT.md](SUPPORT.md).
