---
name: create-release
description: Use when preparing or triggering a MacActivity alpha, beta, rc, or production release
---

# Create Release

Use this when preparing a MacActivity release from GitHub Actions.

## Core Rule

Release creation is two-phase. Always run a clean dry run first, wait for the
result, then ask before creating a draft GitHub Release. Never publish directly
from Actions.

The release workflow never commits or pushes source version changes. It injects
the requested version into the runner workspace before packaging. The checked-in `MARKETING_VERSION` stays `0.1.0` as the development placeholder. Release versions are injected only in the runner workspace and verified against the built app bundle, artifact name, tag, and GitHub Release metadata.

## Version Rule

Use calendar-versioned release trains. The first public alpha starts at
`26.0.0-alpha.1`; the matching final release is `26.0.0`.

Confirm the intended channel and version:

- `alpha`, `beta`, and `rc` create prerelease tags like `v26.0.0-alpha.1`
- `release` creates the final tag like `v26.0.0`
- `version` must be `MAJOR.MINOR.PATCH`
- `prerelease` is the alpha/beta/rc sequence number in the tag suffix; leave it empty for `release`
- `build` is the bundle `CFBundleVersion` and Sparkle version; it must advance across the whole version train, or be omitted to use the workflow run number

Pick the CI suite:

- `full`: SwiftPM tests and Xcode tests
- `swiftpm`: SwiftPM tests only
- `xcode`: Xcode tests only
- `skip`: packaging only; use only for reruns after reviewing CI

## Phase 0: Version plan

Always run the planner before triggering Actions. It checks existing tags,
published releases, and draft releases.

If channel, version, and build are known:

```bash
python3 .github/scripts/plan_release.py \
  --channel alpha \
  --version 26.0.0 \
  --prerelease 1 \
  --build 1 \
  --remote
```

If version, prerelease, or build is missing, ask the planner for a suggestion first:

```bash
python3 .github/scripts/plan_release.py \
  --channel alpha \
  --release-year 26 \
  --remote
```

Do not start dry run when the planner reports conflicts. If the planner only
prints a suggestion, ask whether to use that exact channel, version,
prerelease, and build.

## Phase 1: Clean dry run

Do not create a GitHub Release or tag in phase 1.

```bash
gh workflow run release.yml \
  --ref main \
  -f channel=alpha \
  -f version=26.0.0 \
  -f prerelease=1 \
  -f build=1 \
  -f ci_suite=full \
  -f signing=developer-id \
  -f create_github_release=false
```

```bash
gh run list --workflow release.yml --limit 5
gh run watch <run-id>
gh run download <run-id> --dir /tmp/macactivity-release
```

Inspect the run conclusion, artifact, checksum, and release notes expectation.
Stop and ask whether to create the draft release for the exact tag that passed
the dry run.

## Phase 2: Draft GitHub Release

Only continue after explicit confirmation. The workflow always creates GitHub
Releases as drafts; there is no `draft=false` path.

Prefer reusing the successful phase 1 artifact instead of rebuilding. Pass the
dry-run workflow run ID as `source_run_id`; the workflow verifies the source run,
downloaded artifact checksums, release metadata, and Developer ID signatures
before creating the draft.

```bash
gh workflow run release.yml \
  --ref main \
  -f channel=alpha \
  -f version=26.0.0 \
  -f prerelease=1 \
  -f build=1 \
  -f ci_suite=skip \
  -f signing=developer-id \
  -f create_github_release=true \
  -f source_run_id=<dry-run-id>
```

## Distribution Notes

`signing=local` creates an ad-hoc signed app suitable for workflow artifacts and
internal smoke checks only. GitHub Release assets must use `signing=developer-id`
so the app is Developer ID signed, notarized, stapled, and Gatekeeper-assessed.
