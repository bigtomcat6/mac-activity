# Live SMC Power Flow

## Approved Goal

Replace cached AppleSmartBattery power telemetry with live SMC input and battery
readings. Preserve the two-column endpoint UI and visible-only three-second
sampling. Present power allocated to the Mac rather than an independent system
load sensor. The user approved this direction and an isolated worktree.

## Evidence And Limits

On Mac16,1, PowerTelemetryData stayed unchanged for nearly a minute while SMC
VD0R and ID0R changed every second. AlDente 1.35.1 computes systemPowerIn from
these two SMC keys. B0AV and B0AC provide battery voltage and signed current.
The separate PSTR system-load sensor is not the screenshot's single 29.36 W
adapter-to-Mac flow. AlDente's final branching/label mapping in all charging
states is not fully verified; do not claim a complete algorithm reconstruction.

## Contract

- External watts come only from a fresh VD0R/ID0R pair, never adapter ratings,
  PowerTelemetryData, PSTR, or an old successful sample.
- Battery watts come from B0AV/B0AC in the same acquisition. Negative current
  supplies power; positive current receives power. Do not veto live current
  using a slower IOPS charging flag.
- Mac allocation is external input plus battery discharge minus battery charge.
  This allocation includes the non-battery side of the flow, not an independent
  hardware measurement of system load or a separate loss estimate.
- Known zero battery current means an idle battery with zero contribution.
  Missing current means an unknown contribution and unavailable Mac allocation.
- An absent battery contributes zero; an unreadable present battery does not.
- Disconnected external power contributes zero regardless of retained input
  sensor values. Connected but unreadable input makes Mac allocation unavailable.
- Omit measured-zero external and battery flows from the active columns. Keep
  connected external endpoints with unavailable readings visible.
- Reject non-finite values, negative external input, invalid voltage/current
  combinations, overflow, underflow of nonzero power, and nonpositive Mac totals.
  Do not clamp inconsistent power balances to zero.
- Decode only verified key/type layouts. Input float readings are in V/A and
  converted to mV/mA internally. B0AV ui16 and B0AC si16 use the observed
  little-endian battery register layout in mV/mA. Unknown layouts are unavailable.
- Watts use up to two fractional digits. Keep the existing mW presentation for
  sub-watt values and leave process energy estimates unchanged.
- No new dependencies, root helper, charging controls, persistent history,
  smoothing, background polling, or automatic commits/pushes.
- Keep macOS 13.0 deployment support and existing fan/temperature behavior.

## Verification

Unit tests cover paused charging, charging, battery-only, supplemental battery
discharge, missing/invalid readings, zero versus unavailable, signed decoding,
the real B0AV bytes c2 30 (=12482 mV), and two-decimal formatting. Reuse existing
visible-session cancellation and main-thread isolation tests. Run SwiftPM tests,
the Xcode test scheme, lint, and a read-only live probe without changing power
settings. Physical charging/discharging comparisons that require user actions
remain explicitly unverified until performed.
