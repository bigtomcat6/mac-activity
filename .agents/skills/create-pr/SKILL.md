---
name: mac-activity:create-pr
description: Create a MacActivity pull request with the repository title convention, PR template, and local verification notes.
---

# Create Pull Request

Use this when creating or drafting a PR for MacActivity.

## Steps

1. Inspect the branch:

```bash
git status --short
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
```

2. Pick a title from `.github/pull_request_title_conventions.md`:

```text
<type>(<scope>): <Summary>
```

Prefer these scopes: `app`, `core`, `dashboard`, `actives`, `metrics`, `prefs`,
`release`, `docs`.

3. Fill `.github/pull_request_template.md` with concrete content:

- Summary: what changed and why
- How to test: exact commands or manual checks
- Release impact: user-facing note or `None`
- Checklist: only check items the author has actually done

4. Validate the draft body before creating the PR:

```bash
python3 .github/scripts/check_pr_metadata.py \
  --title "<type>(<scope>): <Summary>" \
  --body-file /tmp/macactivity-pr-body.md
```

5. Create the PR:

```bash
gh pr create --draft --base main --title "<title>" --body-file /tmp/macactivity-pr-body.md
```

## Security Note

This repository is public. For security-sensitive fixes, describe the validation
or hardening behavior without naming an exploit path in branch names, titles,
PR body, tests, or comments.
