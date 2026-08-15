# Power Flow Live Telemetry Design

## Problem

The current Power Flow service intentionally renders external adapters and the
Mac endpoint as unavailable. On this Apple Silicon Mac, the battery is on AC
power at 91 percent and not charging, so `InstantAmperage` and `Amperage` are
zero and the battery correctly has no active row. The same `AppleSmartBattery`
registry entry exposes live input telemetry that the service does not read:

- `SystemVoltageIn` and `SystemCurrentIn` agree with `SystemPowerIn` at about
  27.5 W.
- `SystemLoad` reports the same current system load while the battery is idle.
- The adapter details report 100 W capability, which must remain excluded from
  live-power presentation.

## Goals

- Show a current external-input watt value only from device-provided live
  telemetry, never from adapter capability or negotiated limits.
- Show a current Mac-output watt value only from device-provided system-load
  telemetry.
- Preserve the existing battery direction, invalid-value, privacy, and stale
  snapshot protections.
- Degrade each endpoint independently to `Power unavailable` when telemetry
  is absent, invalid, or inconsistent.

## Collection And Validation

`SystemPowerFlowReader` will read only these numeric children of the existing
`PowerTelemetryData` dictionary from `AppleSmartBattery`:

- `SystemVoltageIn` in millivolts
- `SystemCurrentIn` in milliamps
- `SystemPowerIn` in milliwatts
- `SystemLoad` in milliwatts

For the external input endpoint, the service calculates watts from
`SystemVoltageIn * SystemCurrentIn / 1_000_000`. It publishes that value only
when voltage, current, and `SystemPowerIn / 1_000` are finite and positive,
and the calculated and reported values differ by no more than the larger of
0.5 W or 5 percent. This cross-check rejects a stale, unsupported, or
misinterpreted field rather than presenting an estimate.

For the Mac output endpoint, the service converts a finite, positive
`SystemLoad` from milliwatts to watts. `SystemLoad` is a direct system-load
meter from the same single registry snapshot; no value is inferred from the
adapter, battery, or power balance.

The registry fields are hardware and macOS-version dependent. Their absence,
zero, non-finite value, or an input cross-check failure produces
`PowerFlowMeasurement.unavailable`. No previous sample is retained.

## Data Model

The internal raw reading gains optional telemetry values for input voltage,
input current, reported input power, and system load. The public endpoint
types remain unchanged. `PowerFlowService.snapshot()` maps validated raw input
and system-load telemetry to the external input and Mac output endpoint
measurements respectively.

Battery handling remains unchanged: confirmed discharge is input, confirmed
charge is output, and zero or contradictory current is idle. Adapter
description remains classification-only and is never shown as raw data.

## Tests And Validation

Fixture tests will cover:

- Valid 19,654 mV, 1,399 mA, and 27,471 mW input telemetry producing about
  27.5 W for the external endpoint.
- The same valid 27,471 mW system load producing about 27.5 W for the Mac
  endpoint.
- Missing, zero, negative, non-finite, and cross-check-mismatched telemetry
  producing unavailable measurements.
- Adapter capabilities never overriding or becoming a live measurement.

Manual validation on this Mac will confirm that the Energy Impact page shows
matching live external-input and Mac-output values while AC is connected and
the battery is idle. A Mac without these fields must still show unavailable
values without crashing.

## Privacy And Scope

Only the listed numeric values are read. No serial number, adapter identifier,
or raw registry dictionary is logged, persisted, or rendered. This change does
not add totals, history, background polling, or preference controls.
