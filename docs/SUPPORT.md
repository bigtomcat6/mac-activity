# Support

Use this guide to choose the right support path for MacActivity.

## Usage Questions

Start with:

- [README.md](../README.md)
- [User guide](user-guide.md)
- [Development guide](development.md), for local build or test questions

If the answer is still unclear, open a GitHub issue and describe what you are
trying to do.

## Bug Reports

Open a GitHub issue for reproducible bugs. Include:

- macOS version.
- Mac model and Apple Silicon or Intel architecture.
- MacActivity version, commit, or release artifact.
- Whether the app was launched from Xcode, Finder, a local build script, or a
  downloaded artifact.
- Steps to reproduce.
- Expected result.
- Actual result.
- Screenshots or logs when relevant.

For dashboard or metric issues, include which metric is wrong or unavailable
and whether the issue changes after reopening the dashboard.

For cleanup issues, include the cleanup surface used, the selected cleanup
scope, and whether files were locked, still in use, or protected by permissions.

## Feature Requests

Open a GitHub issue with:

- The problem the feature should solve.
- The current workaround, if any.
- The proposed user-visible behavior.
- Any macOS permission, privacy, or hardware constraints you already know about.

## Security Reports

Do not file public issues for vulnerabilities or privacy-sensitive reports. See
[SECURITY.md](SECURITY.md).

## Out of Scope

MacActivity support does not cover general macOS administration, unrelated Xcode
installation problems, or hardware sensor behavior that macOS does not expose to
apps.
