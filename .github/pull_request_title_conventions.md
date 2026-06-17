# Pull Request Title Conventions

Format:

```text
<type>(<scope>): <Summary>
```

Scope is optional. Summary uses imperative present tense, starts with a capital
letter, and does not end with a period.

## Types

- `feat`: user-facing feature
- `fix`: bug fix
- `perf`: performance or energy improvement
- `test`: test-only change
- `docs`: documentation-only change
- `refactor`: behavior-neutral code change
- `build`: project, dependency, or packaging setup
- `ci`: GitHub Actions or automation
- `chore`: maintenance

## Scopes

- `app`
- `core`
- `dashboard`
- `actives`
- `metrics`
- `prefs`
- `release`
- `docs`

## Changelog Rules

`feat`, `fix`, and `perf` normally appear in release notes. Add `(no-changelog)`
only when the change is intentionally internal.

Examples:

```text
feat(metrics): Add hardware battery percentage preference
fix(dashboard): Keep swap card visible when total swap is zero
perf(app): Reduce status item redraw work
ci(release): Add PR metadata checks
refactor(core): Simplify metric snapshot formatting (no-changelog)
```
