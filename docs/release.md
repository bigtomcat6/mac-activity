# Release Guide

Release automation lives in `.github/workflows/` and `.github/scripts/`.

Run commands from the Swift project directory unless stated otherwise:

```bash
cd mac-activity
```

## Channels

| Channel | Tag shape | GitHub release state | Sparkle updater channel |
| --- | --- | --- | --- |
| `alpha` | `v26.0.0-alpha.1` | Prerelease | alpha |
| `beta` | `v26.0.0-beta.1` | Prerelease | beta |
| `rc` | `v26.0.0-rc.1` | Prerelease | not published to appcast |
| `release` | `v26.0.0` | Latest release | release |

`version` must be `MAJOR.MINOR.PATCH`. For alpha, beta, and rc builds,
`prerelease` is the tag suffix sequence number, such as `2` in
`v26.0.0-beta.2`; leave it empty for final releases. `build` is the bundle
`CFBundleVersion` and Sparkle version. It must keep increasing across the whole
version train and can differ from the prerelease number. When `build` is empty,
the workflow uses the GitHub run number.

MacActivity uses calendar-versioned release trains. The first public alpha for
the current train is `26.0.0-alpha.1`; the matching final release is `26.0.0`.

The workflow injects release versions into the runner workspace only. It does
not commit release version changes back to the repository. The checked-in
development placeholder remains in `Configuration/Shared.xcconfig`.

## Signing Policy

The release workflow supports three signing inputs:

| Input | Use |
| --- | --- |
| `local` | Ad-hoc signing for internal smoke checks only. |
| `project` | Checked-in Xcode project signing settings. Not the distribution path. |
| `developer-id` | Distribution signing, notarization, stapling, DMG signing, and Gatekeeper validation. |

Final `release` channel builds must use `signing=developer-id`.

Any workflow run that creates a GitHub Release must also use
`signing=developer-id`.

Developer ID signing requires the `release-signing` environment secrets and
variables used by `.github/workflows/release.yml`, including the Developer ID
certificate, certificate password, Apple ID notarization credentials, team ID,
and signing identity.

## CI Selection

The release workflow can run one selected CI suite before packaging:

| Input | Checks |
| --- | --- |
| `full` | SwiftPM tests and Xcode tests. |
| `swiftpm` | SwiftPM tests only. |
| `xcode` | Xcode tests only. |
| `skip` | No CI. Use only for reruns after CI was reviewed. |

Normal PR and push CI should use the full reusable CI workflow.

## Planning

Check conflicts against existing tags, published releases, and draft releases
before running a release:

```bash
cd mac-activity
python3 .github/scripts/plan_release.py \
  --channel alpha \
  --version 26.0.0 \
  --prerelease 1 \
  --build 1 \
  --remote
```

When version, prerelease, or build has not been chosen yet, ask for a
suggestion:

```bash
cd mac-activity
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

It verifies the generated Xcode project is current, resolves release metadata,
and validates these bundle fields:

- `CFBundleShortVersionString`
- `CFBundleVersion`
- `MacActivityReleaseTag`

The package job creates:

- DMG.
- App zip.
- dSYM zip.
- SHA256 checksum manifest.
- Generated release notes.

Developer ID runs also notarize the app, sign and notarize the DMG, validate the
DMG contents, run `codesign`, validate stapling, and run `syspolicy_check`.

## Draft GitHub Release

Set `create_github_release=true` to create a draft GitHub Release and upload the
DMG, zip, dSYM zip, and checksum manifest. Alpha, beta, and rc builds are marked
as prereleases. The workflow always uses draft releases; publish from the GitHub
web UI after reviewing notes and assets.

Dry run example:

```bash
cd mac-activity
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

Draft release example:

```bash
cd mac-activity
gh workflow run release.yml \
  --ref main \
  -f channel=alpha \
  -f version=26.0.0 \
  -f prerelease=1 \
  -f build=1 \
  -f ci_suite=full \
  -f signing=developer-id \
  -f create_github_release=true
```

## Sparkle Appcast

MacActivity uses Sparkle for in-app updates. The app bundle contains:

- `SUFeedURL=https://bigtomcat6.github.io/mac-activity/appcast.xml`
- `SUAllowsAutomaticUpdates=true`
- `SUEnableAutomaticChecks=true`
- `SUPublicEDKey` from `SPARKLE_PUBLIC_ED_KEY`

The app preference `updateChannel` defaults to `release`.

Visible update channels are cumulative:

- `release`: release only.
- `beta`: release and beta.
- `alpha`: release, beta, and alpha.

The `appcast.yml` workflow runs when a GitHub Release is published or when it is
manually dispatched with a tag. It publishes only final, beta, and alpha tags.
RC tags are intentionally skipped by the appcast workflow.

The workflow downloads `MacActivity-${TAG}.zip`, writes the release body to a
matching Markdown release-notes file, builds Sparkle's `generate_appcast` tool,
and updates `appcast.xml` on `gh-pages`.

Sparkle's documented path is to use `generate_appcast` for appcast generation
and EdDSA signing. If release notes are changed after appcast generation,
rerun appcast generation so the signed feed and release-note metadata stay
valid.

The appcast workflow requires `SPARKLE_ED_PRIVATE_KEY`.

## Release-Note Labels

Release notes are generated from merged pull requests by
`.github/scripts/generate_release_notes.py`.

Apply one release-note label to every release-relevant PR before merge. Use
`skip-release-notes` for PRs that should not appear in user-facing release
notes.

| Label | Release notes behavior | Use for |
| --- | --- | --- |
| `breaking` | Breaking Changes section | User-visible incompatible changes, removed behavior, migration-required changes. |
| `security` | Security section | Security fixes, permission hardening, privacy-sensitive fixes. |
| `feature` | Features section | New user-visible app behavior, release assets, or visible capabilities. |
| `bugfix` | Bug Fixes section | User-visible correctness fixes, packaging fixes, regression fixes. |
| `performance` | Performance section | Faster behavior, lower resource usage, responsiveness improvements. |
| `other` | Other Changes section | Release-relevant changes that do not fit the categories above. |
| `skip-release-notes` | Excluded from release notes | Internal-only CI, docs, tests, refactors, tooling, formatting. |

`skip-release-notes` has the highest priority. If multiple non-skip labels are
present, the generator uses this priority:

```text
breaking > security > feature > bugfix > performance > other
```

Avoid multiple non-skip release-note labels unless that priority outcome is
intentional.
