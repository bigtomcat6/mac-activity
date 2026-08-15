# Power Flow Live Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show validated live external-input and Mac-output watts from AppleSmartBattery telemetry without ever using adapter capability values as live power.

**Architecture:** Keep IORegistry collection inside `SystemPowerFlowReader`, carry only normalized optional numeric telemetry through a small internal raw type, and put all unit conversion and acceptance rules in `PowerFlowRules`. `PowerFlowService` maps the two validated measurements to the existing external-input and Mac-output endpoints; the SwiftUI presentation remains unchanged.

**Tech Stack:** Swift 6, Foundation, IOKit, IOKit.ps, XCTest, XcodeGen.

## Global Constraints

- Read only `SystemVoltageIn`, `SystemCurrentIn`, `SystemPowerIn`, and `SystemLoad` from `PowerTelemetryData`.
- `SystemVoltageIn` is millivolts, `SystemCurrentIn` is milliamps, and the two power fields are milliwatts.
- Publish external input only when voltage/current and reported power are finite, positive, and agree within `max(0.5 W, 5%)`.
- Publish Mac output only from finite, positive `SystemLoad`; never infer it from a power balance.
- Never use `Watts`, `Current`, or `AdapterVoltage` adapter capability fields as a live measurement.
- Missing, zero, negative, non-finite, or inconsistent values must produce `.unavailable`, never `0 W` or a retained previous value.
- Do not log, persist, render, or add tests containing hardware identifiers or raw IORegistry dumps.
- Regenerate `MacActivity.xcodeproj` with XcodeGen so the committed generated project contains all Power Flow sources and tests.
- Do not commit unless the user explicitly requests a commit.

---

### Task 1: Add Pure Live-Telemetry Measurement Rules

**Files:**
- Modify: `Sources/MacActivityCore/Metrics/Providers/PowerFlowTypes.swift:81-125`
- Modify: `Tests/MacActivityCoreTests/PowerFlowTypesTests.swift`

**Interfaces:**
- Consumes: optional mV, mA, and mW values from the internal reader.
- Produces: `PowerFlowRules.externalInputMeasurement(voltageMillivolts:currentMilliamps:reportedPowerMilliwatts:) -> PowerFlowMeasurement` and `PowerFlowRules.macOutputMeasurement(systemLoadMilliwatts:) -> PowerFlowMeasurement`.
- Used by: `PowerFlowService.snapshot()` in Task 2.

- [ ] **Step 1: Add failing domain-rule tests**

Append these tests to `PowerFlowTypesTests.swift` before changing production code:

```swift
func testExternalInputMeasurementUsesMatchingLiveVoltageCurrentAndPower() {
    let measurement = PowerFlowRules.externalInputMeasurement(
        voltageMillivolts: 19_654,
        currentMilliamps: 1_399,
        reportedPowerMilliwatts: 27_471
    )

    guard case .watts(let watts) = measurement else {
        return XCTFail("Expected a validated live input measurement")
    }
    XCTAssertEqual(watts, 27.496, accuracy: 0.001)
}

func testExternalInputMeasurementRejectsInvalidOrInconsistentTelemetry() {
    let invalidInputs: [(Double?, Double?, Double?)] = [
        (nil, 1_399, 27_471),
        (19_654, nil, 27_471),
        (19_654, 1_399, nil),
        (0, 1_399, 27_471),
        (19_654, 0, 27_471),
        (19_654, 1_399, 0),
        (.nan, 1_399, 27_471),
        (19_654, .infinity, 27_471),
        (19_654, 1_399, 65_000),
    ]

    for (voltage, current, reportedPower) in invalidInputs {
        XCTAssertEqual(
            PowerFlowRules.externalInputMeasurement(
                voltageMillivolts: voltage,
                currentMilliamps: current,
                reportedPowerMilliwatts: reportedPower
            ),
            .unavailable
        )
    }
}

func testMacOutputMeasurementUsesOnlyPositiveFiniteSystemLoad() {
    XCTAssertEqual(
        PowerFlowRules.macOutputMeasurement(systemLoadMilliwatts: 27_471),
        .watts(27.471)
    )

    for invalidLoad: Double? in [nil, 0, -1, .nan, .infinity] {
        XCTAssertEqual(
            PowerFlowRules.macOutputMeasurement(systemLoadMilliwatts: invalidLoad),
            .unavailable
        )
    }
}
```

- [ ] **Step 2: Run the focused rule tests to verify RED**

Run:

```bash
swift test --filter PowerFlowTypesTests
```

Expected: compilation fails because the two live-telemetry rule methods do not exist.

- [ ] **Step 3: Add the smallest truthful conversion rules**

Append these methods inside `PowerFlowRules` in `PowerFlowTypes.swift`:

```swift
static func externalInputMeasurement(
    voltageMillivolts: Double?,
    currentMilliamps: Double?,
    reportedPowerMilliwatts: Double?
) -> PowerFlowMeasurement {
    guard let voltageMillivolts,
          let currentMilliamps,
          let reportedPowerMilliwatts,
          voltageMillivolts.isFinite,
          currentMilliamps.isFinite,
          reportedPowerMilliwatts.isFinite,
          voltageMillivolts > 0,
          currentMilliamps > 0,
          reportedPowerMilliwatts > 0 else {
        return .unavailable
    }

    let calculatedWatts = voltageMillivolts * currentMilliamps / 1_000_000
    let reportedWatts = reportedPowerMilliwatts / 1_000
    guard calculatedWatts.isFinite,
          reportedWatts.isFinite,
          calculatedWatts > 0,
          reportedWatts > 0 else {
        return .unavailable
    }

    let tolerance = max(0.5, max(calculatedWatts, reportedWatts) * 0.05)
    guard abs(calculatedWatts - reportedWatts) <= tolerance else {
        return .unavailable
    }
    return .watts(calculatedWatts)
}

static func macOutputMeasurement(
    systemLoadMilliwatts: Double?
) -> PowerFlowMeasurement {
    guard let systemLoadMilliwatts,
          systemLoadMilliwatts.isFinite,
          systemLoadMilliwatts > 0 else {
        return .unavailable
    }

    let watts = systemLoadMilliwatts / 1_000
    guard watts.isFinite, watts > 0 else {
        return .unavailable
    }
    return .watts(watts)
}
```

- [ ] **Step 4: Run the focused rule tests to verify GREEN**

Run:

```bash
swift test --filter PowerFlowTypesTests
```

Expected: all `PowerFlowTypesTests` pass.

- [ ] **Step 5: Inspect the scope without committing**

Run:

```bash
git diff --check
git diff -- Sources/MacActivityCore/Metrics/Providers/PowerFlowTypes.swift Tests/MacActivityCoreTests/PowerFlowTypesTests.swift
```

Expected: only the two rule methods and their tests are changed; no adapter capability value becomes a measurement.

### Task 2: Collect, Map, And Validate Live Telemetry

**Files:**
- Modify: `Sources/MacActivityCore/Metrics/Providers/PowerFlowService.swift:5-249`
- Modify: `Tests/MacActivityCoreTests/PowerFlowServiceTests.swift`
- Modify: `MacActivity.xcodeproj/project.pbxproj` (generated by XcodeGen)

**Interfaces:**
- Consumes: Task 1's `externalInputMeasurement` and `macOutputMeasurement` rules.
- Produces: validated measurements for the existing `external-power` input and `mac` output endpoints.
- Retains: `PowerFlowRawExternalAdapter` capability fields only for classification/test isolation.

- [ ] **Step 1: Add failing service and reader-fixture tests**

Add these tests to `PowerFlowServiceTests.swift` before adding the raw telemetry type, its default field, or any production mapping code:

```swift
func testServiceUsesValidatedLiveTelemetryForExternalInputAndMacOutput() async {
    let snapshot = await service(reading: PowerFlowRawReading(
        timestamp: Date(timeIntervalSince1970: 7),
        isExternalPowerConnected: true,
        battery: nil,
        externalAdapter: PowerFlowRawExternalAdapter(
            hasUSBPowerDeliveryMetadata: true,
            adapterDescription: "pd charger",
            reportedWatts: 100,
            reportedCurrentMilliamps: 5_000,
            reportedVoltageMillivolts: 20_000
        ),
        telemetry: PowerFlowRawTelemetry(
            inputVoltageMillivolts: 19_654,
            inputCurrentMilliamps: 1_399,
            inputPowerMilliwatts: 27_471,
            systemLoadMilliwatts: 27_471
        )
    )).snapshot()

    guard case .watts(let inputWatts) = snapshot.inputEndpoints.first?.measurement else {
        return XCTFail("Expected live external input watts")
    }
    guard case .watts(let macWatts) = snapshot.outputEndpoints.last?.measurement else {
        return XCTFail("Expected live Mac output watts")
    }
    XCTAssertEqual(inputWatts, 27.496, accuracy: 0.001)
    XCTAssertEqual(macWatts, 27.471, accuracy: 0.001)
}

func testServiceDoesNotFallBackToAdapterCapabilityWhenLiveTelemetryIsInvalid() async {
    let snapshot = await service(reading: PowerFlowRawReading(
        timestamp: Date(timeIntervalSince1970: 8),
        isExternalPowerConnected: true,
        battery: nil,
        externalAdapter: PowerFlowRawExternalAdapter(
            hasUSBPowerDeliveryMetadata: true,
            adapterDescription: "pd charger",
            reportedWatts: 100,
            reportedCurrentMilliamps: 5_000,
            reportedVoltageMillivolts: 20_000
        ),
        telemetry: PowerFlowRawTelemetry(
            inputVoltageMillivolts: 19_654,
            inputCurrentMilliamps: 1_399,
            inputPowerMilliwatts: 65_000,
            systemLoadMilliwatts: .nan
        )
    )).snapshot()

    XCTAssertEqual(snapshot.inputEndpoints.first?.measurement, .unavailable)
    XCTAssertEqual(snapshot.outputEndpoints.last?.measurement, .unavailable)
}

func testPowerTelemetryReadingKeepsOnlyExpectedNumericValues() {
    let telemetry = SystemPowerFlowReader.powerTelemetryReading([
        "SystemVoltageIn": NSNumber(value: 19_654),
        "SystemCurrentIn": NSNumber(value: 1_399),
        "SystemPowerIn": NSNumber(value: 27_471),
        "SystemLoad": NSNumber(value: 27_471),
        "Unrelated": "ignored",
    ])

    XCTAssertEqual(telemetry.inputVoltageMillivolts, 19_654)
    XCTAssertEqual(telemetry.inputCurrentMilliamps, 1_399)
    XCTAssertEqual(telemetry.inputPowerMilliwatts, 27_471)
    XCTAssertEqual(telemetry.systemLoadMilliwatts, 27_471)
}
```

- [ ] **Step 2: Run focused service tests to verify RED**

Run:

```bash
swift test --filter PowerFlowServiceTests
```

Expected: compilation fails because `PowerFlowRawTelemetry`, `telemetry`, and `powerTelemetryReading` do not exist.

- [ ] **Step 3: Add an internal normalized telemetry carrier**

Add near the existing raw types in `PowerFlowService.swift`:

```swift
struct PowerFlowRawTelemetry: Equatable, Sendable {
    let inputVoltageMillivolts: Double?
    let inputCurrentMilliamps: Double?
    let inputPowerMilliwatts: Double?
    let systemLoadMilliwatts: Double?

    static let unavailable = PowerFlowRawTelemetry(
        inputVoltageMillivolts: nil,
        inputCurrentMilliamps: nil,
        inputPowerMilliwatts: nil,
        systemLoadMilliwatts: nil
    )
}
```

Add a defaulted field to `PowerFlowRawReading` so every existing fixture stays
unavailable unless it intentionally supplies telemetry:

```swift
let telemetry: PowerFlowRawTelemetry = .unavailable
```

- [ ] **Step 4: Read only telemetry numeric fields and map them through Task 1 rules**

Make these exact structural changes in `PowerFlowService.swift`:

```swift
// In BatteryRegistryReading:
let telemetry: PowerFlowRawTelemetry

// In both early BatteryRegistryReading returns:
telemetry: .unavailable

// In the normal BatteryRegistryReading return:
telemetry: powerTelemetryReading(
    dictionaryProperty("PowerTelemetryData", service: service)
)

// In the PowerFlowRawReading return from read():
telemetry: registry.telemetry
```

Add this internal reader helper next to `batteryPowerSourceDescription`:

```swift
static func powerTelemetryReading(
    _ details: [String: Any]?
) -> PowerFlowRawTelemetry {
    PowerFlowRawTelemetry(
        inputVoltageMillivolts: number(in: details, key: "SystemVoltageIn"),
        inputCurrentMilliamps: number(in: details, key: "SystemCurrentIn"),
        inputPowerMilliwatts: number(in: details, key: "SystemPowerIn"),
        systemLoadMilliwatts: number(in: details, key: "SystemLoad")
    )
}
```

Replace the external and Mac endpoint hardcoded measurements with:

```swift
let externalMeasurement = PowerFlowRules.externalInputMeasurement(
    voltageMillivolts: raw.telemetry.inputVoltageMillivolts,
    currentMilliamps: raw.telemetry.inputCurrentMilliamps,
    reportedPowerMilliwatts: raw.telemetry.inputPowerMilliwatts
)
let macMeasurement = PowerFlowRules.macOutputMeasurement(
    systemLoadMilliwatts: raw.telemetry.systemLoadMilliwatts
)
```

Use `externalMeasurement` for the existing external endpoint and
`macMeasurement` for the existing Mac endpoint. Do not alter connector
classification, battery direction, endpoint IDs, or adapter capability fields.

- [ ] **Step 5: Run focused Core tests to verify GREEN**

Run:

```bash
swift test --filter 'PowerFlowTypesTests|PowerFlowServiceTests'
```

Expected: all Power Flow Core tests pass, including invalid telemetry safely
remaining unavailable.

- [ ] **Step 6: Regenerate and validate the Xcode project**

Run:

```bash
xcodegen generate --quiet
xcodebuild -project MacActivity.xcodeproj -scheme MacActivity -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -quiet build
```

Expected: the generated project retains the complete Power Flow source/test
membership and the app build succeeds without `PowerFlowModel` or
`PowerFlowView` scope errors.

- [ ] **Step 7: Run complete verification and inspect the final diff**

Run:

```bash
swift test
xcodebuild test -project MacActivity.xcodeproj -scheme MacActivity -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -quiet
git diff --check
git status --short
```

Expected: both test suites pass; the only tracked changes are the live
telemetry rules/service/tests, generated `MacActivity.xcodeproj/project.pbxproj`,
and this approved design/plan documentation. Do not commit unless the user
explicitly asks.

## Plan Self-Review

- **Spec coverage:** Task 1 implements units, tolerance, invalid-value handling, and direct Mac-load conversion. Task 2 limits registry reads to the four approved numeric keys, preserves adapter capability isolation, maps validated results to existing endpoints, regenerates the Xcode project, and verifies both build systems.
- **No placeholders:** Every task names source/test paths, exact commands, expected outcomes, test cases, and production interfaces.
- **Type consistency:** `PowerFlowRawTelemetry` carries the same four values named in the spec; Task 2 calls the two exact `PowerFlowRules` APIs introduced by Task 1.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-15-power-flow-live-telemetry.md`. Two execution options:

1. **Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - Execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
