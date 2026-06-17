---
name: create-release
description: Use when preparing or triggering a MacActivity alpha, beta, rc, or production release
---

# Create Release

Use this when preparing a MacActivity release from GitHub Actions.

## Checks

1. Confirm the intended channel and version:

- `alpha`, `beta`, and `rc` create prerelease tags like `v0.2.0-beta.45`
- `release` creates the final tag like `v0.2.0`
- `version` must be `MAJOR.MINOR.PATCH`
- `build` must be a positive integer, or omitted to use the workflow run number

2. Pick the CI suite:

- `full`: SwiftPM tests and Xcode tests
- `swiftpm`: SwiftPM tests only
- `xcode`: Xcode tests only
- `skip`: packaging only; use only for reruns after already reviewing CI

3. Decide whether the source version should be committed:

- Leave `commit_version_change=false` for artifact-only preview builds.
- Use `commit_version_change=true` for a reproducible release tag.

4. Trigger the workflow:

```bash
gh workflow run release.yml \
  --ref main \
  -f channel=beta \
  -f version=0.2.0 \
  -f ci_suite=full \
  -f signing=local \
  -f create_github_release=false \
  -f commit_version_change=false \
  -f draft=true
```

5. Watch and fetch the result:

```bash
gh run list --workflow release.yml --limit 5
gh run watch <run-id>
gh run download <run-id> --dir /tmp/macactivity-release
```

## Distribution Notes

`signing=local` creates an ad-hoc signed app suitable for workflow artifacts and
internal smoke checks. Use `signing=project` only after the repository has the
required signing identity and runner secrets for distribution signing.
