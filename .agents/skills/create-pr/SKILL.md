---
name: create-pr
description: Use when creating or drafting a MacActivity pull request, optionally targeting the next-version branch via `/create-pr next`
---

# Create Pull Request

Use this when creating or drafting a PR for MacActivity.

## Target

Resolve the base branch from the invocation argument and assign `BASE`:

- `next` -> `next-version`
- `main` or no argument -> `main`

Example: `/create-pr next` sets `BASE=next-version`.

## Steps

1. Inspect the branch against the base:

```bash
BASE=main # or BASE=next-version
git status --short
git diff --stat "origin/${BASE}...HEAD"
git log --oneline "origin/${BASE}..HEAD"
git log --format='%s' "origin/${BASE}..HEAD"
```

2. Pick a title from `.github/pull_request_title_conventions.md`:

```text
<type>(<scope>): <Summary>
```

Prefer these scopes: `app`, `core`, `dashboard`, `actives`, `metrics`, `prefs`,
`release`, `docs`.

3. Pick exactly one release-note PR label from the branch commits.

Use commit subjects as the primary signal and the diff only to disambiguate.
Do not use GitHub default labels like `bug` or `enhancement` for release notes.

| Branch signal | Label |
| --- | --- |
| Breaking or incompatible user/workflow behavior, `!`, or `BREAKING CHANGE` | `breaking` |
| Security, privacy, permission, signing, notarization hardening | `security` |
| User-visible new app behavior, visible capability, metric, preference, or release asset | `feature` |
| User-visible correctness fix, regression fix, packaging fix | `bugfix` |
| Faster, lighter, lower-energy, or more responsive behavior | `performance` |
| Release-relevant change that does not fit above | `other` |
| CI-only, docs-only, test-only, refactor-only, formatting, tooling, dependency maintenance with no release-facing effect | `skip-release-notes` |

For mixed branches, ignore supporting docs/tests/CI commits and choose the
best label for the user-facing outcome. If multiple release-note labels could
apply, use the generator priority:

```text
breaking > security > feature > bugfix > performance > other
```

Use `skip-release-notes` only when the whole PR should be excluded from release
notes. Do not combine `skip-release-notes` with a release-note label.

4. Fill `.github/pull_request_template.md` with concrete content:

- Summary: what changed and why
- How to test: exact commands or manual checks
- Release impact: align with the chosen label. Use `None` only with
  `skip-release-notes`.
- Checklist: only check items the author has actually done

5. Validate the draft body before creating the PR:

```bash
python3 .github/scripts/check_pr_metadata.py \
  --title "<type>(<scope>): <Summary>" \
  --body-file /tmp/macactivity-pr-body.md
```

6. Create the draft PR against the resolved base with the chosen label:

```bash
gh pr create --draft --base "${BASE}" \
  --title "<title>" \
  --body-file /tmp/macactivity-pr-body.md \
  --label "<release-note-label>"
```

7. Verify the created PR has the intended label and base:

```bash
gh pr view --json number,title,baseRefName,labels \
  --jq '{number, title, base: .baseRefName, labels: [.labels[].name]}'
```

## Security Note

This repository is public. For security-sensitive fixes, describe the validation
or hardening behavior without naming an exploit path in branch names, titles,
PR body, tests, or comments.
