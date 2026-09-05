# Live SMC Power Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove cached device-power values and implement the approved live input/battery allocation contract.

**Architecture:** Reuse SMCSensorReader's existing read-only connection and key reader. Decode four verified keys in a small power-specific reader, retain IOKit for topology/classification, and keep deterministic allocation in PowerFlowRules. No dependency on AlDente or independent PSTR reading.

**Tech Stack:** Swift 6, IOKit/AppleSMC, SwiftUI, XCTest, SwiftPM, XcodeGen.

## Global Constraints

- Deployment target remains macOS 13.0.
- Keep visible-only 3_000_000_000 ns sampling, cancellation, and off-main reads.
- Use only SMC commands 9 (key info) and 5 (read bytes).
- No fallback to PowerTelemetryData or adapter capabilities for live watts.
- Missing is not zero. Nonpositive/invalid Mac allocation is unavailable.
- No dependencies, helper, charging changes, automatic commits, or pushes.
- Follow `docs/superpowers/specs/2026-09-05-power-flow-smc-design.md`.

---

### Task 1: Read And Decode Live SMC Power

**Files:**
- Create: `Sources/MacActivityCore/Metrics/Providers/PowerFlowSMCReader.swift`
- Modify: `Sources/MacActivityCore/Metrics/Providers/FanProvider.swift`
- Test: `Tests/MacActivityCoreTests/PowerFlowSMCReaderTests.swift`

**Interfaces:**
- Consumes existing `SMCSensorReader.SMCReading`, `withConnection`, `readKey`, and float decoder. Make only those needed by the new reader internal; keep existing fan/temperature decoding unchanged.
- Produces `PowerFlowSMCReader.read() -> PowerFlowSMCReader.Reading` and injectable `read(readKey: (String) -> SMCSensorReader.SMCReading?) -> Reading`.
- `Reading` has optional `inputVoltageMillivolts`, `inputCurrentMilliamps`, `batteryVoltageMillivolts`, and `batteryCurrentMilliamps`, defaulting to nil.

- [x] Add decoder tests before production code. Use real bytes and explicit invalid layouts:

```swift
let reading = PowerFlowSMCReader.read { key in
    switch key {
    case "B0AV": return .init(bytes: [0xC2, 0x30], dataType: "ui16")
    case "B0AC": return .init(bytes: [0x30, 0xF8], dataType: "si16")
    default: return nil
    }
}
XCTAssertEqual(reading.batteryVoltageMillivolts, 12_482)
XCTAssertEqual(reading.batteryCurrentMilliamps, -2_000)
XCTAssertNil(reading.inputVoltageMillivolts)
```

- [x] Run `swift test --filter PowerFlowSMCReaderTests`; verify missing-reader failure.
- [x] Implement only the four keys. For VD0R/ID0R accept `flt ` and decode the first four little-endian float bytes, reject non-finite values, then multiply by 1000. For B0AV/B0AC accept respectively `ui16`/`si16`, require two bytes, and decode as follows:

```swift
let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
let voltage = Double(raw)
let current = Double(Int16(bitPattern: raw))
```

- [x] Use one existing SMC connection for all four reads. Failed/missing keys become nil independently. Add tests for both signs, zero, truncated values, unexpected data types, and non-finite floats.
- [x] Run `swift test --filter 'PowerFlowSMCReaderTests|SMCSensorReaderTests'`; expect all deterministic tests passing, unchanged fan/temperature behavior.

### Task 2: Wire Sampling And Allocate Endpoints

**Files:**
- Modify: `Sources/MacActivityCore/Metrics/Providers/SystemPowerFlowReader.swift`
- Modify: `Sources/MacActivityCore/Metrics/Providers/PowerFlowService.swift`
- Modify: `Sources/MacActivityCore/Metrics/Providers/PowerFlowTypes.swift`
- Test: `Tests/MacActivityCoreTests/PowerFlowServiceTests.swift`
- Test: `Tests/MacActivityCoreTests/PowerFlowTypesTests.swift`

**Interfaces:**
- Consumes Task 1's fresh sensor reading.
- Keep `PowerFlowRawTelemetry` with only input voltage/current. Remove registry reported power/system load fields and parser.
- Keep raw battery voltage/current; remove `isCharging` from raw battery and `batteryState` arguments.
- `macOutputMeasurement(externalInput: PowerFlowMeasurement, batteryState: PowerFlowBatteryState) -> PowerFlowMeasurement` replaces direct SystemLoad conversion.

- [x] Add a regression with the old interfaces first: input 20,000 mV/1,468 mA and cached system load 28,810 mW, battery current zero. Assert Mac receives 29.36 W, not 28.81 W. Add charge/discharge allocations and confirm behavior failures before updating implementation.
- [x] Represent a known idle battery as `PowerFlowBatteryState(direction: .idle, measurement: .watts(0))`; unknown current remains idle/unavailable. Derive nonzero direction solely from the signed live current.
- [x] Remove the reported-input-power veto and validate voltage/current directly. Known zero current with valid nonnegative voltage gives zero watts; a positive current with zero voltage is unavailable.
- [x] Compute allocation only after verifying both contributions:

```swift
guard let input = externalInput.watts, let battery = batteryState.measurement.watts,
      input.isFinite, battery.isFinite, input >= 0, battery >= 0 else {
    return .unavailable
}
let watts = input + (batteryState.direction == .input ? battery : -battery)
guard watts.isFinite, watts > 0 else { return .unavailable }
return .watts(watts)
```

- [x] In `PowerFlowService`, compute battery state once; absent battery contributes idle/zero. Disconnected external power contributes `.watts(0)` and never creates an external endpoint. Connected external input with measured zero is omitted; missing input stays visible/unavailable. Append Mac allocation instead of SystemLoad.
- [x] In `SystemPowerFlowReader`, read topology/classification using existing IOKit APIs and numeric power via `PowerFlowSMCReader.read()`. Build battery data only when present; remove registry current/voltage/PowerTelemetryData and signed-registry-current helpers. Timestamp the completed acquisition. Do not add a registry fallback.
- [x] Update obsolete fixture interfaces and replace SystemLoad/cross-check expectations with the approved allocation contract. Include 40 W input/18 W charge -> 22 W Mac; 20 W input/24 W discharge -> 44 W Mac; battery-only 24 W -> 24 W Mac; unknown present battery -> unavailable; impossible negative balance -> unavailable; stale external reading while disconnected -> ignored.
- [x] Run `swift test --filter 'PowerFlowTypesTests|PowerFlowServiceTests|PowerFlowModelTests'`; expect all tests passing including off-main read/cancellation tests.

### Task 3: Presentation, Documentation, And Verification

**Files:**
- Modify: `Sources/MacActivityApp/Models/PowerFlowPresentation.swift`
- Test: `Tests/MacActivityAppTests/PowerFlowPresentationTests.swift`
- Create: `Tests/MacActivityCoreTests/PowerFlowNativeValidationTests.swift`
- Modify: `docs/user-guide.md`
- Regenerate: `MacActivity.xcodeproj/project.pbxproj`

- [x] Change the watts expectation from `22.1 W` to `22.14 W`; add `29.36 W` and a rounding case. Run `swift test --filter PowerFlowPresentationTests`; expect formatting failures.
- [x] Change only the watts formatting precision:

```swift
return "\(watts.formatted(.number.locale(locale).precision(.fractionLength(0...2)))) W"
```

- [x] Document live SMC input/battery readings, derived non-battery Mac allocation, absent sensors, and the independence from process CPU-energy estimates. Keep the existing UI and mW format.
- [x] Run `swift test --filter 'PowerFlow|SMCSensorReader'`, `swift test --enable-code-coverage`, and `git diff --check`.
- [x] Run `xcodegen generate --quiet`, then `xcodebuild test -project MacActivity.xcodeproj -scheme MacActivity -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -quiet`.
- [x] Run `swiftlint lint --quiet` and separate existing warnings from new findings.
- [x] Exercise the actual production reader using an opt-in read-only native test, with no charging/system-setting changes. Confirm source values update and idle input matches Mac allocation. Report physical charging/discharging A/B checks as unperformed unless actually observed.
- [x] Request independent correctness review of the complete diff; fix verified findings with regression tests. Keep changes uncommitted in the isolated worktree for the user.

## Final Evidence (2026-09-06)

- SwiftPM with coverage: 1330 tests, 16 skipped, zero failures.
- Xcode result bundle: Passed, 1314 passed, 16 skipped, zero failures.
- Final native read-only run: three idle-battery samples at 21.41435,
  19.49046, and 19.02180 W; each input matched its Mac allocation.
- Strict lint on all 11 changed Swift files: zero violations. Full-repository
  lint still reports ten pre-existing errors in unrelated Sources/Tests files,
  also reproduced in the unchanged main checkout. No new suppressions added.
- Final review found an UPS-only source incorrectly qualifying as an internal
  battery. A failing regression demonstrated it; internal-only source selection
  fixed it, and re-review found no remaining issues.
- Physical charging, battery-only, supplemental-discharge AlDente comparisons,
  and other hardware models were not tested. These are not claimed as verified.
- Changes remain uncommitted on fix/power-flow-smc; main is unchanged.
