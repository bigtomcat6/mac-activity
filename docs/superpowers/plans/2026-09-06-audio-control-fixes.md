# Audio Control Fixes Implementation Plan

> **For agentic workers:** Use subagent-driven-development to implement and review each task. Do not commit without an explicit user request.

**Goal:** Apply output-device volume during dragging, make repeated per-app route changes recover correctly, and exclude this process from the controllable audio list.

**Architecture:** Preserve the SwiftUI bindings, coordinator, and CoreAudio tap engine. Remove device-volume trailing debounce. Diagnose route-switch cleanup at the native boundary, preserve exact resource ownership, and allow normal asynchronous cleanup to finish a current switch instead of failing it immediately.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest, SwiftUI, CoreAudio, macOS.

## Global Constraints

- macOS 13 remains the application minimum; process controls remain gated to macOS 14.2 or later.
- No new dependencies, layout changes, system-default-output changes, or unrelated refactors.
- Preserve zero-volume mute/restore behavior, confirmed readback, latest-intent ordering, cancellation, and device identity checks.
- Do not create a replacement session while an older acquisition for the same process remains live.
- Do not discard retained resources, weaken ownership checks, or assume a successful aggregate-destroy call means destruction is complete.
- Diagnose exact stages and OSStatus values; no audio samples are recorded or logged.
- Keep code, tests, and diagnostics in this isolated worktree on fix/audio-control-fixes.
- No commits, installation, permission changes, or interaction with unrelated running applications.

## Baseline

- Base revision: `2e75b81`.
- `swift test --filter 'Audio.*Tests|ProcessTap.*Tests'`: 547 tests passed, zero failures.
- User reproduction: first per-app output selection to built-in speakers or a display normally succeeds; second selection to any device fails, and retry remains unsuccessful.
- Apple documents `AudioHardwareDestroyAggregateDevice` as asynchronous: https://developer.apple.com/documentation/coreaudio/audiohardwaredestroyaggregatedevice(_:)

## Task 1: Continuous Device Volume

**Files:**
- Modify `Sources/MacActivityApp/Models/AudioControlCoordinator.swift`.
- Test `Tests/MacActivityAppTests/AudioControlCoordinatorTests.swift`.
- Update related device-control fixture tests only where their synchronization assumes debounce.

**Interface:** Keep `setDeviceVolume(_:for:)` and the existing view/model bindings unchanged.

- [ ] Add a regression test submitting a device value, yielding to the control task, and asserting a hardware write before any injected delay is released. Submit another value in a later event turn and assert another write. Always release test continuations during cleanup so a red test cannot hang.

```swift
fixture.coordinator.setDeviceVolume(0.6, for: "BuiltIn")
for _ in 0..<12 { await Task.yield() }
XCTAssertEqual(fixture.deviceProvider.volumeWrites, [0.6])
fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
for _ in 0..<12 { await Task.yield() }
XCTAssertEqual(fixture.deviceProvider.volumeWrites, [0.6, 0.8])
await delay.resumeAll()
await fixture.coordinator.testingWaitUntilIdle()
```

- [ ] Run `swift test --filter AudioControlCoordinatorTests/testDeviceVolumeWritesDuringContinuousDrag` and verify the hardware-write assertions fail on the original implementation.
- [ ] Remove the `debounceVolume` plumbing and the 75ms volume wait. Preserve serialized device tasks, ordinal/lifetime checks, successful readback merging, and error rollback. Update debounce-dependent tests to synchronize on actual task submission or the existing provider write hooks.
- [ ] Run `swift test --filter 'AudioControlCoordinatorTests|AudioControlComponentTests|AudioDashboardViewTests'`. Verify continuous writes, coalescing within one event turn, mute/restore, shutdown, stale device identity, refresh, and failure rollback.
- [ ] Review the task diff for spec compliance and quality before proceeding.

## Task 2: Exclude the Current Audio Process

**Files:**
- Modify `Sources/MacActivityCore/Audio/AudioProcessService.swift`.
- Test `Tests/MacActivityCoreTests/AudioProcessServiceTests.swift`.

**Interface:** Preserve `AudioProcessProviding.audibleOutputProcesses()` and stable CoreAudio process-object identity.

- [ ] Add injected discovery tests including the current PID, another running PID, and a non-running output process. Include missing Workspace metadata and an unrelated process named Mac Activity.

```swift
let ownPID = ProcessInfo.processInfo.processIdentifier
let ownSnapshot = AudioProcessSnapshot(
    processObjectID: 11,
    processIdentifier: ownPID,
    bundleIdentifier: nil,
    isRunningOutput: true
)
```

- [ ] Run `swift test --filter AudioProcessServiceTests` and verify the new self-exclusion assertions fail.
- [ ] Filter the current PID before publishing entries, without filtering display names or adding compatibility parameters.

```swift
let ownPID = ProcessInfo.processInfo.processIdentifier
let snapshots = processSnapshotReader().filter { $0.processIdentifier != ownPID }
return Self.makeEntries(processObjects: snapshots, apps: appSnapshotReader())
```

- [ ] Run `swift test --filter AudioProcessServiceTests` and review the task diff.

## Task 3: Complete Repeated Route Switches Safely

**Files:**
- Modify `Sources/MacActivityCore/Audio/ProcessTapVolumeEngine.swift`.
- Modify `Sources/MacActivityCore/Audio/AudioTapHardware.swift` only for a demonstrated native identity/probe defect.
- Test `Tests/MacActivityCoreTests/ProcessTapVolumeEngineTests.swift`.
- Test `Tests/MacActivityCoreTests/AudioTapHardwareDescriptionTests.swift`.
- Extend `Tests/MacActivityCoreTests/Support/FakeAudioTapHardware.swift` only to model the observed asynchronous lifecycle accurately.
- Add coordinator/component coverage if an interface or snapshot contract changes.

**Interface:** Keep `ProcessTapVolumeControlling.apply(plan:gain:)` asynchronous and terminal for its caller. Existing `rebuilding` snapshots may describe nonterminal progress. Only the current generation may install or confirm a replacement.

- [ ] Reproduce the native lifecycle if the local audio setup and capture permission permit it. Record stage, owned object identity, and raw status. Do not prompt for broader permissions or modify another app's settings; report any native-verification limitation.
- [ ] Reproduce delayed aggregate destruction with the existing fake. First apply succeeds; second apply must wait for the exact old acquisition to disappear rather than return `cleanupBacklogFull`; after cleanup, the same request completes successfully. Verify no new tap is created before cleanup and no intermediate failed snapshot is published.

```swift
let fixture = EngineFixture()
let first = await fixture.engine.apply(
    plan: fixture.plan(generation: 1), gain: ProcessGainState()
)
XCTAssertEqual(first.state, .running)
fixture.hardware.deferAggregateDisappearance = true
// Submit the next apply in a Task, observe its first identity probe, then
// complete the fake aggregate destruction and advance the retry scheduler.
// Assert the pending apply returns running without submitting another apply.
```

- [ ] Add tests for a third generation superseding a pending second switch, cancellation/shutdown during cleanup, bounded waiting, genuine teardown failure, exact object-ID reuse, and 20 successive route rebuilds. Use controlled hardware/scheduler events rather than arbitrary sleeps.
- [ ] Run the new tests and record their expected failures before changing lifecycle behavior.
- [ ] Implement the smallest current-request continuation across proven normal asynchronous cleanup. Keep timeout/cancellation explicit, never block the engine queue waiting for work scheduled on that same queue, retain failures and owned resources on timeout, and revalidate route freshness before preparing after a wait. Keep original-audio restoration and exact resource destruction order unless native evidence proves a separate ordering defect.
- [ ] If a post-destroy `kAudioHardwareBadObjectError` is reproduced, treat that exact error as disappearance in the aggregate probe; preserve unknown errors and replacement-object checks. Cover it with native HAL-fake tests before implementation.
- [ ] Run `swift test --filter 'ProcessTap.*Tests|AudioTapHardwareDescriptionTests|AudioControlComponentTests|AudioControlCoordinatorTests'` and review the task diff.

## Task 4: Final Verification and Handoff

- [ ] Update `docs/user-guide.md` with continuous volume behavior and the self-exclusion rule, without promising unsupported hardware compatibility.
- [ ] Run `swift test --filter 'Audio.*Tests|ProcessTap.*Tests'`, then `swift test` and `git diff --check`.
- [ ] Perform a whole-change correctness review, resolve important findings, and rerun affected tests.
- [ ] Where hardware is available, verify repeated built-in/display switching, dragging before mouse-up, and clean exit. Report native validation separately from fake-backed unit tests.
- [ ] Leave all intended changes uncommitted in this worktree and report its path, test results, and remaining native verification limits.

## Execution Results

- Device-volume debounce removed; deterministic drag and stale-device coverage retained.
- Current PID excluded before publishing controllable process entries, including when Workspace metadata is missing.
- Normal delayed aggregate destruction now resumes the same pending route request after exact cleanup, with cancellation, bounded retries, and current-generation rebuilding progress.
- Final integration review also found and fixed late route/gain completion during a Core Audio service restart. Pending intents are invalidated before stopAll and confirmed profiles are restored without stale writes.
- Per-task and final independent reviews completed with no remaining findings.
- `swift test --filter 'Audio.*Tests|ProcessTap.*Tests'`: 564 tests, zero failures.
- `swift test`: 1335 tests, 15 environment-gated skips, zero failures.
- `swift build -c release`: passed.
- `git diff --check`: passed.
- Native preflight was read-only and found no running audio output process or display route. Physical volume response, display route switching, and native service restart remain unverified; no capture permission or audio settings were changed.
- Changes remain uncommitted on `fix/audio-control-fixes` in `.worktrees/audio-control-fixes`; the main checkout is unchanged.
