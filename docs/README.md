# MacActivity Documentation

This directory is the canonical documentation root for the MacActivity
repository.

Do not add project docs under nested docs directories such as
`docs/mac-activity`.

## Start Here

- [User guide](/docs/user-guide.md): app behavior, metrics, preferences, cleanup, and
  updater channels.
- [Development guide](/docs/development.md): local setup, repository layout, build,
  test, localization, and documentation rules.
- [Contributing guide](/docs/CONTRIBUTING.md): issue and pull request workflow,
  expected tests, title format, and release impact rules.
- [Release guide](/docs/release.md): release channels, signing, packaging, draft
  releases, Sparkle appcast publishing, and release-note labels.
- [Support guide](/docs/SUPPORT.md): usage questions, bug reports, diagnostics, and
  out-of-scope support.
- [Security policy](/docs/SECURITY.md): private reporting path for security-sensitive
  issues.
- [Documentation strategy](/docs/documentation-strategy.md): why this docs layout
  exists and what to improve later.

## Documentation Rules

- Put durable project documentation directly under `docs/`.
- Update [user-guide.md](/docs/user-guide.md) for user-visible app behavior.
- Update [development.md](/docs/development.md) for build, test, architecture,
  localization, or tooling changes.
- Update [release.md](/docs/release.md) for release workflow, artifact, versioning,
  updater, or release-note behavior changes.
- Update [CONTRIBUTING.md](/docs/CONTRIBUTING.md) when pull request expectations,
  title rules, or review requirements change.

## Writing Style

- Write for the next reader trying to complete a task.
- Prefer concrete commands, file paths, and expected outcomes.
- Avoid duplicating detailed instructions in multiple files. Link to the
  canonical file instead.
- Keep policy pages short enough to read before filing an issue or opening a
  pull request.
