# Physical Power Flow Endpoints Design

**Date:** 2026-08-15

## Purpose

Add a physical power-flow summary to the existing Energy Impact dashboard. It
shows active input and output endpoints with current, directly measured power
when the hardware exposes it. The existing application CPU energy-impact list
remains below the new summary.

The feature must not present adapter capacity, energy-impact estimates, or a
calculated balance as live physical power.

## Scope

- Add input and output endpoint lists above the existing application ranking.
- Show an endpoint's type as its row name: `USB-C`, `MagSafe`, `Battery`,
  `Mac`, or `Unknown External Interface`.
- Show a current value in watts only when it is directly supported by a valid
  hardware measurement.
- Keep a recognized endpoint visible when its current power is unavailable.
- Refresh only while the Energy Impact page is visible, at the existing
  approximately three-second cadence.
- Localize all new visible and accessibility text in the application's seven
  supported languages.

## Non-Goals

- Do not replace the application energy-impact ranking.
- Do not derive whole-Mac power from charger capacity, battery power, or an
  energy balance.
- Do not display an adapter's negotiated or rated watts as current input power.
- Do not add totals, trends, history, preferences, menu-bar values, or
  background sampling.
- Do not infer USB-C, MagSafe, or another connector type from wattage or an
  unstructured adapter name.

## User Interface

The Energy Impact page starts with a compact two-column power-flow section:

- **Input** lists endpoints currently supplying power.
- **Output** lists endpoints currently receiving or using power.
- The current application energy-impact heading and ranking follow the section
  unchanged, including their separate up-to-30-second CPU energy semantics.

Each row contains an endpoint icon, its type name, and a trailing current
power value such as `22.1 W`. If a source is known but direct power is not
available, the trailing value is the localized equivalent of `Power
Unavailable`.

`Mac` is always an output endpoint. `Battery` moves between the lists:

- During confirmed discharge, `Battery` is an input endpoint.
- During confirmed charge, `Battery` is an output endpoint.
- When idle, it remains in the data snapshot but is omitted from both active
  lists. An empty list states that it has no active endpoints.

An external endpoint uses its confirmed connector type as the row name. If the
hardware cannot confirm a type, the row name is `Unknown External Interface`.
No generic external-power label or duplicate type badge is shown.

The section must remain readable in the existing 420-point dashboard width.
Names truncate before power values; a missing value remains explicit rather
than being replaced with `0 W`.

## Architecture

The design separates hardware collection, normalized domain data, lifecycle,
and rendering.

### Core Collection

A Core-only power-flow service reads IOKit power-source and IORegistry data.
It owns source discovery, connector classification, measurement validation,
and snapshot construction. It has no SwiftUI or dashboard lifecycle logic.

The normalized snapshot contains a sampling timestamp and independently
renderable endpoint records. An endpoint record contains:

- A stable identifier.
- An endpoint type.
- A flow direction: input, output, or idle.
- A current measurement in watts, or an unavailable state.
- The reason the endpoint is present, for accessibility and diagnostics.

The service exposes an injectable protocol so Core and App tests can use fixed
hardware readings without querying the machine's actual power hardware.

### App Lifecycle and Presentation

An App-side observable model owns the visible-page refresh task. It requests a
fresh snapshot about every three seconds while the Energy Impact page is
visible and cancels the task when the page is hidden. It publishes an entire
new snapshot atomically so the two lists never combine endpoint states from
different samples.

The SwiftUI view renders only normalized endpoint records. It does not read
IOKit data, calculate watts, classify connector types, or retain old values.

## Measurement and Classification Rules

The collector may use power-source descriptions and `AppleSmartBattery`
IORegistry data already used by the battery metric. Battery power is valid only
when current and voltage are both finite, non-negative after normalization, and
their reported direction agrees with charging-state metadata. The conversion is:

```text
watts = abs(millivolts * milliamps) / 1,000,000
```

The current direction and charging metadata determine whether a valid battery
measurement belongs to input or output. Missing, contradictory, non-finite, or
invalid values produce an unavailable measurement and never a zero value.

External endpoints are discovered individually where the system exposes them.
Their connector type is classified only from an explicit structured connector
metadata field with a known connector value. Free-text adapter or product
descriptions are not parsed for classification. A watt value is shown only if
the same hardware source exposes live voltage and current that can be
validated. Adapter capacity, negotiated voltage/current limits, and rated
wattage are not measurements and remain unavailable.

`Mac` may show watts only if the hardware exposes a direct, valid whole-system
meter. Otherwise, it remains visible in Output with power unavailable.

## Failure Handling

Every published snapshot represents the current sampling attempt. A failed or
partial read does not keep a prior watt value on screen. Known endpoint types
remain visible with power unavailable when possible; an endpoint that cannot
be discovered at all is absent from that snapshot.

The feature does not show a total because one or more active endpoints may be
unknown. This prevents an incomplete set of measurements from looking like a
power balance.

## Accessibility and Localization

New strings use the existing localization mechanism and are supplied in every
supported language. Each endpoint row is one accessibility element whose label
states its direction, endpoint type, and either current watts or the
unavailable state. Connector names such as `USB-C` and `MagSafe` remain
recognizable technical labels inside localized text.

## Testing and Validation

Core unit tests cover:

- IOKit/IORegistry fixture mapping to endpoint types and directions.
- Valid milliamp/millivolt-to-watt conversion.
- Rejection of missing, non-finite, negative, and contradictory readings.
- Battery charge, discharge, and idle transitions.
- External endpoints with recognized and unknown connector types.
- The rule that adapter capacity and negotiated limits never become current
  power values.
- Desktop-style snapshots without a battery.

App tests cover:

- Visible-page start, refresh, atomic replacement, and cancellation behavior.
- Input/output placement and the Battery direction transition.
- Explicit unavailable values and no stale watt retention.
- Localized text and accessibility labels.
- Rendering at the existing 420-point dashboard width with long endpoint
  names.

Hardware validation is performed on available machines in these states:

- USB-C external power connected.
- MagSafe external power connected.
- Battery discharge.
- A machine whose hardware does not expose one or more requested readings.

The validation confirms source naming, direction, units, unavailable handling,
and that no capacity value is represented as live power.
