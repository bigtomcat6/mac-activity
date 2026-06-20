# Release Guide

Release automation lives in this repository under `.github/workflows/` and
`.github/scripts/`.

## Channels

| Channel | Tag shape | GitHub release state |
| --- | --- | --- |
| `alpha` | `v26.0.0-alpha.1` | Prerelease |
| `beta` | `v26.0.0-beta.1` | Prerelease |
| `rc` | `v26.0.0-rc.1` | Prerelease |
| `release` | `v26.0.0` | Latest release |

`version` must be `MAJOR.MINOR.PATCH`. `build` must be a positive integer. When
`build` is empty, the workflow uses the GitHub run number.

MacActivity uses calendar-versioned release trains. The first public alpha is
`26.0.0-alpha.1`; the matching final release is `26.0.0`.

The workflow injects release versions into the runner workspace only. It does
not commit release version changes back to the repository. The checked-in
development placeholder can remain in `Configuration/Shared.xcconfig`.

## CI Selection

The release workflow can run one selected CI suite before packaging:

| Input | Checks |
| --- | --- |
| `full` | SwiftPM tests and Xcode tests |
| `swiftpm` | SwiftPM tests only |
| `xcode` | Xcode tests only |
| `skip` | No CI; use only for reruns after CI was reviewed |

Normal PR and push CI should use the full reusable CI workflow.

## Planning

Check conflicts against existing tags, published releases, and draft releases
before running a release:

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

It validates bundle versions, creates DMG, zip, and dSYM zip artifacts, writes a
single `SHA256SUMS.txt` manifest, and uploads them as workflow artifacts.

`signing=local` uses ad-hoc signing for internal artifacts and smoke checks.
`signing=project` is reserved for distribution signing after the required
certificates and runner secrets are configured.

## Draft GitHub Release

Set `create_github_release=true` to create a draft GitHub Release and upload the
DMG, zip, dSYM zip, and checksum manifest. Alpha, beta, and rc builds are marked
as prereleases. The workflow uses draft releases; publish from the GitHub web UI
after reviewing notes and assets.

Dry run example:

```bash
gh workflow run release.yml \
  --ref main \
  -f channel=alpha \
  -f version=26.0.0 \
  -f build=1 \
  -f ci_suite=full \
  -f signing=local \
  -f create_github_release=false
```

Draft release example:

```bash
gh workflow run release.yml \
  --ref main \
  -f channel=alpha \
  -f version=26.0.0 \
  -f build=1 \
  -f ci_suite=full \
  -f signing=local \
  -f create_github_release=true
```

## Release-Note Labels

Release notes are generated from merged pull requests by
`.github/scripts/generate_release_notes.py`.

Apply one release-note label to every release-relevant PR before merge. Use
`skip-release-notes` for PRs that should not appear in user-facing release
notes.

| Label | Release notes behavior | Use for |
| --- | --- | --- |
| `breaking` | Breaking Changes section | User-visible incompatible changes, removed behavior, migration-required changes |
| `security` | Security section | Security fixes, permission hardening, privacy-sensitive fixes |
| `feature` | Features section | New user-visible app behavior, release assets, or visible capabilities |
| `bugfix` | Bug Fixes section | User-visible correctness fixes, packaging fixes, regression fixes |
| `performance` | Performance section | Faster behavior, lower resource usage, responsiveness improvements |
| `other` | Other Changes section | Release-relevant changes that do not fit the categories above |
| `skip-release-notes` | Excluded from release notes | Internal-only CI, docs, tests, refactors, tooling, formatting |

`skip-release-notes` has the highest priority. If multiple non-skip labels are
present, the generator uses this priority:

```text
breaking > security > feature > bugfix > performance > other
```

Avoid multiple non-skip release-note labels unless that priority outcome is
intentional.
