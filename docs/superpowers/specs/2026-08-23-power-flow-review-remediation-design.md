# Power Flow Review Remediation Design

## Scope

Address the two verified Codex findings on PR #118 and restore the PR's
Codecov patch-coverage gate without excluding testable service behavior.

## Battery State

`PowerFlowRules.batteryState` will establish a battery direction from a
finite, nonzero current and charging state before it evaluates voltage:

- Negative current with `isCharging == false` is input.
- Positive current with `isCharging == true` is output.
- Nil, non-finite, zero, or contradictory current remains idle.
- An otherwise valid direction with nil, non-finite, or nonpositive voltage
  remains visible with an unavailable measurement.

This preserves the known endpoint direction while continuing to withhold a
power value that cannot be measured safely.

## Registry Current Decoding

Only `InstantAmperage` and fallback `Amperage` will use a signed 32-bit
conversion before becoming `Double`. This restores a negative value when an
AppleSmartBattery registry property is exposed as an unsigned two's-complement
number. Voltage, telemetry, and adapter capability fields retain their current
numeric conversion behavior.

## Coverage Boundary

Move `SystemPowerFlowReader` into its own source file and add that file to the
existing Codecov ignore list alongside `BatterySystemPowerSourceReader.swift`.
The reader makes direct IOKit calls whose hardware-dependent branches cannot be
reproduced in CI. `PowerFlowService`, rules, raw values, model, presentation,
and view code remain covered by deterministic unit tests.

No registry dump, hardware identifier, or raw adapter value will be logged,
persisted, or added to a fixture.

## Tests And Validation

Tests will be written before each production change and will cover:

- Charging and discharging batteries with unavailable voltage retaining their
  direction and using an unavailable measurement.
- A wrapped negative 32-bit registry amperage decoding to the expected
  negative current.
- Remaining uncovered Power Flow model error/deadline, presentation endpoint,
  view symbol, and measurement branches.

Validation will run the focused Power Flow tests, `swift test --enable-code-coverage`,
and the Xcode test suite. After the branch is pushed, `codecov/patch` must meet
the configured 90% target. The two Codex inline threads will receive concise
technical replies describing their fixes.
