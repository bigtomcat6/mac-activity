---
name: create-release
description: Use when preparing, triggering, or verifying a MacActivity alpha, beta, rc, or production release and its appcast/Pages distribution
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
After a final release exists for a train, the next alpha/beta/rc planner
suggestion opens the next minor train, for example `v26.1.0-beta.1` after
`v26.0.0`.

Confirm the intended channel and version:

- `alpha`, `beta`, and `rc` create prerelease tags like `v26.0.0-alpha.1`
- `release` creates the final tag like `v26.0.0`
- `version` must be `MAJOR.MINOR.PATCH`
- `prerelease` is the alpha/beta/rc sequence number in the tag suffix; leave it empty for `release`
- `build` is the bundle `CFBundleVersion` and Sparkle version; it must advance across release trains, or be omitted to use the workflow run number

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

For prereleases, generated release notes are incremental from the latest
reachable tag. For final releases, generated release notes must be cumulative
from the previous final release tag; when there is no previous final release,
the first final release includes the full alpha/beta/rc train.

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

## Post-publish distribution

Creating the draft Release is not the end of the release. Publishing is always a
human action, and distribution may need a second human approval. At the draft
handoff, proactively give the human this checklist instead of stopping silently:

1. Publish the draft GitHub Release in the web UI.
2. Watch the exact-tag `Publish Sparkle appcast` run triggered by that publish.
3. If the run is gated, open the run URL, click **Review deployments**, select
   the pending environment (from `pending_deployments`), then click
   **Approve and deploy**.
4. Verify GitHub Pages and the live feed.

If the session ends before the human publishes, leave distribution explicitly
pending with this checklist. Do not claim the release is end-to-end complete.

### Appcast run correlation

Publishing fires `Publish Sparkle appcast` on the `release: published` event.
Find the run for the exact tag; never assume the newest run is this tag:

```bash
gh run list --workflow appcast.yml --event release \
  --json databaseId,headBranch,displayTitle,status,conclusion,url
gh run view <run-id> --json status,conclusion,jobs,url
gh api "repos/<owner>/<repo>/actions/runs/<run-id>/pending_deployments"
```

Match `headBranch`/`displayTitle` to the exact tag (a release event ref is the
tag). `rc` tags are skipped by the appcast workflow, so label their updater
status `N/A` instead of waiting.

### Waiting for approval

If a job is waiting, do not assume a runner is available and do not blindly
`gh run watch` a gated run. Query `pending_deployments`, then use the actual
`environment.name` it returns (do not assume it is always `release-signing`),
report the reviewer(s), and give the human the direct run URL with these steps:
open the run URL, click **Review deployments**, select the pending environment,
then click **Approve and deploy**. Never self-approve, bypass environment
protection, move secrets, or edit `environment`/workflow configuration.

### After approval

Confirm the appcast run jobs and any applicable `Deploy GitHub Pages` job
succeed, then check the public feed:

```bash
gh run view <run-id> --json status,conclusion,jobs,url
curl --fail --silent https://bigtomcat6.github.io/mac-activity/appcast.xml
```

The feed must contain the exact expected `shortVersionString`, the release ZIP
enclosure URL for the tag
(`.../releases/download/<tag>/MacActivity-<tag>.zip`), and the right channel:
`alpha`/`beta` entries carry `<sparkle:channel>`, while a final `release` has no
prerelease channel. Clients must select the `alpha` or `beta` update channel to
receive beta updates.

If the appcast run, Pages deployment, or live feed is missing, failed, or not
yet complete, report that exact state as pending or failed. Do not rebuild,
re-publish, or rerun anything without an explicit request.

## Handoff summary

End with these fields so the approval reminder is not buried:

- tag
- GitHub Release: draft or published
- appcast run: ID/link and status
- approval: required? environment/reviewer and the action needed
- Pages/live feed verification: verified, pending, failed, or `N/A` (`rc`)
