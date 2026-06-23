# Contributing to MacActivity

Contributions can include code, documentation, tests, issue triage, release
validation, and reproducible bug reports.

## Before You Start

- For usage questions, read [SUPPORT.md](/docs/SUPPORT.md).
- For security-sensitive reports, read [SECURITY.md](/docs/SECURITY.md) and avoid
  public issue details.
- For release workflow changes, read [release.md](/docs/release.md).
- For local setup, read [development.md](/docs/development.md).

## Issues

Use issues for reproducible bugs, focused feature requests, and release or
packaging problems.

Good bug reports include:

- macOS version.
- Mac model and Apple Silicon or Intel architecture.
- MacActivity version, commit, or release artifact.
- Steps to reproduce.
- Expected result.
- Actual result.
- Screenshots or logs when relevant.

## Pull Requests

Keep pull requests focused. A reviewable PR should make one coherent change and
include the verification used to prove it works.

Before opening a PR:

1. Rebase or merge the latest target branch.
2. Run the focused tests for the changed area.
3. Run broader tests when touching shared behavior, release automation, project
   generation, localization, or app lifecycle code.
4. Update docs in `docs/` when behavior, workflow, or support expectations
   change.
5. Fill out the PR template completely.

## PR Title Format

Use:

```text
<type>(<scope>): <Summary>
```

The scope is optional. The summary starts with a capital letter and does not end
with a period.

Allowed types:

- `feat`: user-facing feature.
- `fix`: bug fix.
- `perf`: performance or energy improvement.
- `test`: test-only change.
- `docs`: documentation-only change.
- `refactor`: behavior-neutral code change.
- `build`: project, dependency, or packaging setup.
- `ci`: GitHub Actions or automation.
- `chore`: maintenance.

Allowed scopes:

- `actives`
- `app`
- `core`
- `dashboard`
- `docs`
- `metrics`
- `prefs`
- `release`

Examples:

```text
feat(metrics): Add hardware battery percentage preference
fix(dashboard): Keep swap card visible when total swap is zero
perf(app): Reduce status item redraw work
ci(release): Add PR metadata checks
docs: Update release checklist
test(release): Cover release metadata parsing
```

## Release Impact

Every PR should make its release impact explicit in the PR template.

- Use a user-facing release note for visible `feat`, `fix`, and `perf` changes.
- Use `Release impact: None` for internal-only work.
- Use `skip-release-notes` for changes that should not appear in generated
  release notes.
- Apply one release-note label before merge when a PR should appear in release
  notes.

See [release.md](/docs/release.md) for the label taxonomy.

## Review Expectations

Review focuses on correctness, user-visible behavior, macOS integration,
regressions, test coverage, and whether documentation matches the change.

Large PRs may be split before review if they combine unrelated UI, core,
release, or documentation changes.
