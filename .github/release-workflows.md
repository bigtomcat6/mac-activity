# MacActivity Release Workflows

Release automation lives in this git repository:

```text
.github/workflows/release.yml
.github/workflows/ci-checks.yml
.github/scripts/plan_release.py
.github/scripts/prepare_release_metadata.py
.github/scripts/generate_release_notes.py
```

## Channels

Use the `Release` workflow from GitHub Actions or the GitHub CLI.

| Channel | Tag shape | GitHub release state |
| --- | --- | --- |
| `alpha` | `v26.0.0-alpha.1` | prerelease |
| `beta` | `v26.0.0-beta.1` | prerelease |
| `rc` | `v26.0.0-rc.1` | prerelease |
| `release` | `v26.0.0` | latest release |

`version` must be `MAJOR.MINOR.PATCH`. `build` must be a positive integer; when
left empty, the workflow uses the GitHub run number.

MacActivity uses calendar-versioned release trains. The first public alpha is
`26.0.0-alpha.1`; the matching final release is `26.0.0`.

The workflow updates `Configuration/Shared.xcconfig` only inside the runner
workspace before building:

```text
MARKETING_VERSION = <version>
CURRENT_PROJECT_VERSION = <build>
```

It does not commit or push that change back to the repository. The checked-in
`MARKETING_VERSION` stays `0.1.0` as the development placeholder. Release
versions are injected only in the runner workspace and expressed through the
tag, GitHub Release, artifact file name, and app bundle metadata.

## CI Selection

The release workflow can run one selected CI suite before packaging:

| Input | Checks |
| --- | --- |
| `full` | SwiftPM tests and Xcode tests |
| `swiftpm` | SwiftPM tests only |
| `xcode` | Xcode tests only |
| `skip` | No CI; use only for reruns after CI was reviewed |

Normal PR and push CI calls the same reusable `ci-checks.yml` workflow with
`suite=full`.

## Planning

Before running Actions, use the planner to check conflicts against existing
tags, published releases, and draft releases:

```bash
python3 .github/scripts/plan_release.py \
  --channel alpha \
  --version 26.0.0 \
  --build 1 \
  --remote
```

When version or build has not been chosen yet, ask for a suggestion:

```bash
python3 .github/scripts/plan_release.py \
  --channel alpha \
  --release-year 26 \
  --remote
```

The release workflow runs the same conflict check before building.

## Packaging

The workflow builds the Release app with:

```bash
scripts/install-local-release.command --build-only --skip-launch --skip-quit
```

It validates `CFBundleShortVersionString` and `CFBundleVersion`, creates DMG,
zip, and dSYM zip artifacts, writes a single `SHA256SUMS.txt` manifest, and
uploads them as workflow artifacts.

`signing=local` uses ad-hoc signing for internal artifacts and smoke checks
only. GitHub Release assets must use `signing=developer-id` so the app is
Developer ID signed, notarized, stapled, and Gatekeeper-assessed. The Developer
ID path requires the `release-signing` environment secrets and variables.

`signing=project` uses the checked-in Xcode project signing settings, but it is
not the distribution path unless the workflow is extended to notarize that
output too.

## GitHub Release

Set `create_github_release=true` to create a draft GitHub Release and upload the
DMG, zip, dSYM zip, and checksum manifest. Alpha, beta, and rc builds are marked prerelease. The
workflow always uses draft releases; publish from the GitHub web UI after
reviewing notes and assets.

Example:

```bash
gh workflow run release.yml \
  --ref main \
  -f channel=alpha \
  -f version=26.0.0 \
  -f build=1 \
  -f ci_suite=full \
  -f signing=developer-id \
  -f create_github_release=false
```

After that dry run passes and the artifact has been reviewed, run the draft
release phase:

```bash
gh workflow run release.yml \
  --ref main \
  -f channel=alpha \
  -f version=26.0.0 \
  -f build=1 \
  -f ci_suite=full \
  -f signing=developer-id \
  -f create_github_release=true
```
