# Support

Use this guide to choose the right support path for MacActivity.

## Usage Questions

Start with:

- [User guide](/docs/user-guide.md)
- [Development guide](/docs/development.md), for local build or test questions
- [Release guide](/docs/release.md), for release artifact or updater questions

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

For Actives process issues, include the affected app name, whether its bundle
identifier is visible, and whether Quit was requested or confirmed.

For cleanup issues, include the cleanup surface used, the selected cleanup
categories, and whether files were locked, still in use, too new for cache
cleanup, or protected by permissions.

For updater issues, include the current app version, selected update channel,
release artifact source, and whether Check for Updates was run manually.

## Feature Requests

Open a GitHub issue with:

- The problem the feature should solve.
- The current workaround, if any.
- The proposed user-visible behavior.
- Any macOS permission, privacy, hardware, signing, or updater constraints you
  already know about.

## Security Reports

Do not file public issues for vulnerabilities or privacy-sensitive reports. See
[SECURITY.md](/docs/SECURITY.md).

## Out of Scope

MacActivity support does not cover general macOS administration, unrelated Xcode
installation problems, or hardware sensor behavior that macOS does not expose to
apps.
