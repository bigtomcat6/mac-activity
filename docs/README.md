# MacActivity Documentation

This directory is the canonical Git-tracked documentation set for MacActivity.
Keep the repository `README.md` short and use this directory for durable user,
contributor, maintainer, and release documentation.

## Start Here

- [User guide](user-guide.md): everyday app behavior, metrics, preferences, and
  cleanup features.
- [Development guide](development.md): local setup, project structure, build,
  test, localization, and documentation update rules.
- [Contributing guide](CONTRIBUTING.md): issue and pull request workflow,
  expected tests, title format, and release impact rules.
- [Release guide](release.md): release channels, CI selection, packaging,
  GitHub draft releases, and release-note labels.
- [Support guide](SUPPORT.md): where to ask usage questions, report bugs, and
  provide reproducible diagnostics.
- [Security policy](SECURITY.md): how to report security-sensitive issues.
- [Documentation strategy](documentation-strategy.md): rationale from GitHub
  Docs and larger open-source projects, plus the backlog for improving this
  documentation set.

## Documentation Rules

- Put project documentation under `docs/`.
- Link from the root `README.md` to stable docs instead of copying long content
  into the README.
- Update [user-guide.md](user-guide.md) for user-visible app behavior.
- Update [development.md](development.md) for build, test, architecture, or
  localization changes.
- Update [release.md](release.md) for release workflow, artifact, versioning, or
  release-note behavior changes.
- Update [CONTRIBUTING.md](CONTRIBUTING.md) when pull request expectations,
  title rules, or review requirements change.

## Writing Style

- Write for the next reader who is trying to complete a task.
- Prefer concrete commands, file paths, and expected outcomes.
- Keep policy pages short enough to be read before filing an issue or opening a
  pull request.
- Avoid duplicating detailed instructions in multiple files. Link to the
  canonical file instead.
