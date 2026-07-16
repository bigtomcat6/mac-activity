# Documentation Strategy

This note records the documentation model for MacActivity and the current
maintenance rules.

## Current Decision

The repository root is the documentation root:

```text
docs/
```

All durable project docs live in `docs/`. Do not add project docs under
`docs/mac-activity` or any other nested docs tree.

## External Patterns Reviewed

The docs layout follows common open-source patterns:

- Keep the README short and task-oriented.
- Use `docs/README.md` as the navigation index.
- Split user, contributor, maintainer, support, and security information into
  stable pages.
- Keep release process details near workflow and automation details, but do not
  duplicate scripts in prose.
- Use precise paths and commands so docs can be reviewed with code changes.

The Sparkle updater documentation also supports the release docs decision to
treat `generate_appcast` as the canonical appcast generation and signing path.

## Local Diagnosis

MacActivity already had code, workflow, and release behavior that deserved
stable docs, but the documentation needed to be refreshed against the current
project code.

The main gaps were:

- No root `docs/README.md` index for project docs.
- User docs did not cover GPU, Disk, Swap, VRAM, update channels, Actives quit
  confirmation, or the process identifier preference.
- Development docs did not describe the current project layout and focused debug
  tools.
- Release docs did not reflect the current Developer ID gate, DMG validation,
  Sparkle appcast workflow, or cumulative update-channel policy.

## Chosen Model

Audience split:

- Users start with [user-guide.md](/docs/user-guide.md) and [SUPPORT.md](/docs/SUPPORT.md).
- Contributors start with [development.md](/docs/development.md) and
  [CONTRIBUTING.md](/docs/CONTRIBUTING.md).
- Maintainers use [release.md](/docs/release.md) for release planning, signing,
  packaging, GitHub Releases, appcast publishing, and release notes.
- Security reporters use [SECURITY.md](/docs/SECURITY.md).
- Documentation maintainers use this file to preserve the rationale and
  backlog.

## Maintenance Rules

- Every user-visible change should update the user guide or explicitly state why
  no user documentation is needed.
- Every build, test, workflow, localization, updater, or release process change
  should update the matching developer or release guide.
- Do not let generated plans, temporary scratch notes, or local agent state
  become permanent docs unless they are edited into a stable guide.

## Backlog

High value:

- Add screenshots or short screen recordings for the menu bar, dashboard,
  preferences, and Actives cleanup flows once the visual surface stabilizes.
- Add issue templates for bug reports and feature requests so reports collect
  the diagnostics listed in [SUPPORT.md](/docs/SUPPORT.md).
- Add a short code ownership map when ownership becomes broader than the current
  `MacActivityApp` and `MacActivityCore` split.
- Add a release artifact troubleshooting section after the first public
  Developer ID release has enough real support data.

Lower priority:

- Add a style guide only after repeated documentation review issues appear.
- Add a public documentation website only after GitHub Markdown is no longer
  enough for the app's user-facing surface.
