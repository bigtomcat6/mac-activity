---
name: mac-activity:pr-readiness-check
description: Check whether a MacActivity pull request is ready for human review.
---

# PR Readiness Check

Use this before asking for review or merging.

## Checks

1. Fetch PR metadata:

```bash
gh pr view <number-or-branch> --json title,body,files,isDraft,mergeStateStatus,statusCheckRollup
```

2. Validate title and body:

```bash
gh pr view <number-or-branch> --json title,body \
  --jq '.body' > /tmp/macactivity-pr-body.md
gh pr view <number-or-branch> --json title \
  --jq '.title' > /tmp/macactivity-pr-title.txt
python3 .github/scripts/check_pr_metadata.py \
  --title "$(cat /tmp/macactivity-pr-title.txt)" \
  --body-file /tmp/macactivity-pr-body.md
```

3. Confirm verification evidence in the PR body:

- SwiftPM tests for core logic changes
- Xcode tests for app/UI/project changes
- Screenshot or manual check for visual behavior
- Release impact is explicit

4. Review changed files for scope:

- One focused behavior per PR
- No unrelated docs, generated files, or formatting churn
- Tests accompany behavior changes unless the PR explains why manual validation
  is the right check

## Output

Report blockers first. If there are none, say which checks passed and what
residual risk remains.
