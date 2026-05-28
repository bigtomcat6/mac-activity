# Actives Clean Release Design

## Goal

Replace the current Actives tab with a compact clean-release page that matches the visible scope and user-facing behavior of Tencent Lemon Cleaner's menu-bar `清理释放` page.

The target page is not the full Lemon main app. It covers only:

- Trash cleanable-size status and cleanup.
- Memory usage status and memory release.
- Foreground app resident-memory ranking with horizontal usage bars.
- Per-app polite quit requests.

The implementation will be original Swift code in MacActivity. Lemon Cleaner's repository is GPL-licensed, so this design uses the observed behavior and structure as a reference and does not copy source code.

## Confirmed Decisions

- Use the close-match layout direction selected in the visual companion: trash section, memory strip, process list.
- Add a confirmation before clearing Trash.
- Keep app closing as a polite `NSRunningApplication.terminate()` request, not a forced kill.
- Keep the feature inside the existing `Actives` tab and dashboard popover shell.

## Out Of Scope

- Lemon main-app deep cleanup.
- Large-file cleanup, duplicate-file cleanup, photo cleanup, privacy cleanup, app uninstall, login item management, disk analyzer, or file move tools.
- Forced process termination.
- Copying Lemon Cleaner assets or source code.
- New long-running privileged helper or daemon.

## Current Context

`DashboardView.swift` currently owns both the dashboard shell and the Actives implementation. The existing Actives model already provides a useful base:

- `ActiveAppMemoryService` lists regular foreground apps and reads resident memory through `proc_pidinfo`.
- `CleanMemoryService` runs `/usr/bin/purge` through an injectable command runner.
- App quit requests call `NSRunningApplication.terminate()`.

The current Actives UI is a single card with a refresh button, a clean-memory button, and up to 8 apps. The new design should keep those tested service seams but move Actives-specific state and UI out of `DashboardView.swift`.

## Architecture

Add an Actives clean-release feature with small, focused units:

- `ActiveCleanupModel`
  - Main-actor observable state for the Actives page.
  - Owns trash status, memory release status, process rows, action messages, and loading flags.
  - Coordinates services but does not do filesystem deletion or process inspection directly.

- `TrashCleanupService`
  - Async service for scanning and emptying Trash.
  - Uses injected filesystem operations for tests.
  - Reports explicit scan and cleanup results.

- `MemoryReleaseService`
  - Wraps the existing `CleanMemoryService` behavior.
  - Reads memory before and after release so the UI can show the amount or percent reclaimed.
  - Keeps command execution injectable.

- `ActiveAppMemoryService`
  - Keeps existing resident-memory reader behavior.
  - Raises default Actives display limit to 20 for this page.
  - Provides enough data for row icon, app name, bundle id when useful, resident bytes, and terminability.

- SwiftUI views:
  - `ActiveCleanReleaseView`
  - `TrashCleanupStatusView`
  - `MemoryReleaseStatusView`
  - `ActiveProcessMemoryList`
  - `ActiveProcessMemoryRow`

`DashboardView` should only select the Actives tab and host `ActiveCleanReleaseView`.

## UI Layout

The Actives tab content follows the Lemon menu-bar clean-release hierarchy:

1. Trash section
   - About 103 points tall.
   - Shows cleanable trash size when available.
   - Shows scanning, cleaning, cleaned, clean, and error states.
   - Primary action is `Clean`; it opens confirmation before deleting.

2. Memory strip
   - About 44 points tall.
   - Shows current memory usage percent.
   - Right-side `Release` action starts memory release.
   - While running, shows a spinner or rotating symbol and `Releasing memory`.
   - After completion, shows the reclaimed amount or percent.

3. Process memory list
   - Rows are about 38 points tall.
   - Shows up to 20 regular foreground apps sorted by resident memory descending.
   - Each row has a horizontal background bar scaled relative to the largest visible process.
   - The row shows icon, app name, and memory size.
   - Hovering a row reveals `Quit` on the right in place of the memory value.

The layout should remain compact and scan-friendly. Avoid nested cards; the clean-release content should read as one panel, not a card inside a card.

## Trash Behavior

On Actives appearance:

1. Start a lightweight async trash scan.
2. Show scanning state until scan completes.
3. If scan fails, show an error state with a retry affordance.
4. If size is zero, show the clean state.
5. If size is nonzero, show the cleanable size and `Clean`.

On `Clean`:

1. Present a confirmation dialog explaining that Trash contents will be deleted.
2. If the user cancels, leave files untouched and show no success state.
3. If confirmed, run cleanup asynchronously.
4. During cleanup, show the cleaning state and disable duplicate cleanup starts.
5. On success, show cleaned state and refresh the computed size.
6. On failure, show an error message and keep the action recoverable.

Trash cleanup should target the user's Trash contents. If later implementation discovers volume-specific Trash locations are necessary for parity, that should be handled by extending `TrashCleanupService`, not by adding UI complexity.

## Memory Release Behavior

The memory release action keeps the existing MacActivity command path and presents Lemon-like result semantics:

1. Read memory usage before release.
2. Run the existing cleaner.
3. Read memory usage after release.
4. Compute reclaimed bytes as `max(0, beforeUsedBytes - afterUsedBytes)`.
5. Compute reclaimed percent against total memory when total memory is available.
6. Show success, unavailable, or failed result.

The command must run off the main actor. The UI must prevent duplicate release actions while one is running.

## Process List Behavior

Process ranking uses foreground regular apps only. This mirrors the menu-bar cleanup page intent: show user-facing apps that can plausibly be quit, not every daemon.

Sorting and row display rules:

- Sort by resident memory descending.
- Tie-break by localized app name.
- Limit to 20 rows.
- Scale each row bar against the largest visible row.
- If no app data is available, show a placeholder state.

`Quit` remains polite:

- Call `NSRunningApplication.terminate()`.
- Do not send SIGKILL.
- If the app disappears before the request, show a not-found message.
- If macOS does not accept the request, show a not-terminable message.
- Refresh the process list after a request.

## Error Handling

Error states should be local to the relevant section:

- Trash scan failed.
- Trash cleanup was cancelled.
- Trash cleanup failed because a file could not be deleted.
- Trash cleanup failed because of permissions.
- Memory release command is unavailable.
- Memory release command failed with an exit code.
- Process is no longer running.
- Process cannot be quit safely.

Global one-line status text may still be useful, but it should not be the only indication of failure.

## Testing

Use test-first implementation for behavior changes.

Core tests:

- Trash scan reports cleanable size.
- Trash scan reports clean state for zero size.
- Trash cleanup does not run before confirmation.
- Confirmed trash cleanup deletes through the injected filesystem service.
- Cancelled trash cleanup leaves files untouched.
- Trash cleanup failure produces an error state.
- Memory release records before and after readings.
- Memory release computes reclaimed bytes and percent with a nonnegative floor.
- Unavailable and failed memory release results propagate to UI state.
- Process ranking defaults to 20 rows for Actives.
- Process rows are sorted by memory and tie-break by name.
- Row bar progress is relative to the largest visible process.
- Quit requests still use polite termination semantics.

UI/layout tests:

- Actives page exposes trash, memory, and process-list zones in order.
- Trash section, memory strip, and process row constants match the compact target sizes.
- Row hover state swaps memory value for `Quit` without resizing the row.

Verification commands should run from the Swift package root:

```sh
cd /Users/how/Git/How/How/MacActivity/mac-activity
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter MemoryProviderTests
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test --filter DashboardCardLayoutTests
CLANG_MODULE_CACHE_PATH=/private/tmp/clang-module-cache swift test
```

## Acceptance Criteria

- Actives visually matches Lemon Cleaner's menu-bar `清理释放` content structure.
- The page shows Trash status, memory release status, and a foreground app memory ranking.
- Trash cleanup requires confirmation before deletion.
- Memory release reports a visible result based on before and after readings.
- Process rows use horizontal bars scaled to visible resident memory.
- Up to 20 foreground apps are shown.
- App `Quit` requests remain polite and never force kill.
- Failures are visible and recoverable.
- Existing overview dashboard behavior is unchanged.
- Focused tests and full Swift test suite pass.
