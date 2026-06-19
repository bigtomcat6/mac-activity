# Release Note PR Labels

Release notes are generated from merged pull requests by
`.github/scripts/generate_release_notes.py`.

Agents working on PRs should apply one release-note label to every PR before it
is merged. Use `skip-release-notes` for PRs that should not appear in user-facing
release notes.

## Labels

| Label | Release notes behavior | Use for |
| --- | --- | --- |
| `breaking` | `## ⚠️ Breaking Changes` | User-visible incompatible changes, removed behavior, migration-required changes |
| `security` | `## 🔒 Security` | Security fixes, permission hardening, privacy-sensitive fixes |
| `feature` | `## ✨ Features` | New user-visible app behavior, new release assets, new visible capabilities |
| `bugfix` | `## 🐛 Bug Fixes` | User-visible correctness fixes, packaging fixes, regression fixes |
| `performance` | `## ⚡ Performance` | Faster behavior, lower resource usage, responsiveness improvements |
| `other` | `## Other Changes` | Release-relevant changes that do not fit the categories above |
| `skip-release-notes` | Excluded from release notes | Internal-only CI, docs, tests, refactors, tooling, formatting |

## Priority

`skip-release-notes` has the highest priority. If it is present, the PR is
excluded even when another release-note label is also present.

If multiple non-skip labels are present, the generator uses the first match in
this order:

```text
breaking > security > feature > bugfix > performance > other
```

Avoid applying multiple non-skip release-note labels unless the priority outcome
is intentional.

## Classification Guidance

Use `feature` when the release note should tell testers or users that something
new is available. Examples include adding a DMG artifact, adding a visible app
control, or adding a new metric surface.

Use `bugfix` when the release note should tell testers or users that something
wrong is fixed. Examples include fixing generated release notes, repairing
packaging assets, or correcting app behavior.

Use `performance` only when the user-visible outcome is faster, lighter, or more
responsive. Internal-only optimization with no release-facing effect can use
`skip-release-notes`.

Use `security` for security or privacy changes even when the implementation also
looks like a bug fix.

Use `breaking` for incompatible behavior, removed support, changed assumptions,
or anything that requires a user or downstream workflow to adapt.

Use `other` for release-relevant work that users or testers may need to know
about but that does not fit a more specific label.

Use `skip-release-notes` for PRs that are valuable to the repository but not
useful in a release note:

```text
ci-only changes
internal documentation
test-only changes
refactors without behavior changes
formatting cleanup
tooling maintenance
dependency maintenance with no user-visible effect
```

## Generated Output

Empty sections are omitted. Unmatched PRs fall back to `## Other Changes`, but
agents should still apply an explicit label so the release intent is reviewable.

Example:

```markdown
## ✨ Features

- Add DMG packaging for alpha releases. (#12)

## 🐛 Bug Fixes

- Stop duplicate generated release notes. (#13)

## Other Changes

- Update release workflow metadata. (#14)
```
