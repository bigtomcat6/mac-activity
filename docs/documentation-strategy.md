# Documentation Strategy

This note records the documentation model chosen for MacActivity after comparing
GitHub's repository documentation guidance and several large open-source
projects.

## External Patterns Reviewed

- GitHub Docs treats a repository README as the front door: it should explain
  what the project does, why it is useful, how to get started, where to get help,
  and who maintains it. GitHub also surfaces community health files such as
  README, code of conduct, license, contribution guidelines, issue templates,
  support resources, and security policy.
- Kubernetes keeps its documentation repository README task-oriented: it links
  contribution docs, localization docs, local preview commands, prerequisites,
  troubleshooting, and maintainer contact paths.
- React's documentation repository uses the README as a fast setup path with
  prerequisites and local contribution instructions, while deeper documentation
  lives outside the README.
- Homebrew's README routes readers to the manual, installation,
  troubleshooting, contribution guide, FAQ, blog, and license details instead of
  duplicating all content in the repository README. Its prose guidelines put
  understandability ahead of style for its own sake.
- Swift's compiler repository uses `docs/README.md` as a curated index into the
  rest of the repository documentation and points new contributors to the right
  community channel when docs are not enough.
- Node.js uses CONTRIBUTING.md to define contribution types, issue paths, pull
  request process, governance expectations, and automation rules.

Primary references:

- GitHub Docs, community profiles:
  https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories
- GitHub Docs, repository README:
  https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes
- Kubernetes documentation repository:
  https://github.com/kubernetes/website/
- React documentation repository:
  https://github.com/reactjs/react.dev
- Homebrew repository and prose style:
  https://github.com/Homebrew/brew and https://docs.brew.sh/Prose-Style-Guidelines
- Swift documentation index:
  https://github.com/swiftlang/swift/blob/main/docs/README.md
- Node.js contributing guide:
  https://github.com/nodejs/node/blob/main/CONTRIBUTING.md

## Local Diagnosis

Before this documentation pass, MacActivity had a useful root README and several
GitHub workflow notes, but it did not have a Git-tracked `docs/` information
architecture for users, contributors, maintainers, security reports, and
support.

The main gaps were:

- No canonical `docs/README.md` index.
- No user guide for dashboard, preferences, metric availability, and cleanup
  behavior.
- No contributor guide that combines local expectations, PR title rules, release
  impact rules, and documentation requirements.
- No GitHub-recognizable support or security policy under `docs/`.
- Release workflow knowledge existed, but it was not part of the main
  documentation navigation.

## Chosen Model

MacActivity should use the README as a short front door and keep durable
documentation under `docs/`.

Audience split:

- Users start with [user-guide.md](user-guide.md) and [SUPPORT.md](SUPPORT.md).
- Contributors start with [development.md](development.md) and
  [CONTRIBUTING.md](CONTRIBUTING.md).
- Maintainers use [release.md](release.md) for release planning, packaging, and
  release notes.
- Security reporters use [SECURITY.md](SECURITY.md).
- Documentation maintainers use this file to preserve the rationale and backlog.

## Maintenance Rules

- Every user-visible change should update the user guide or explicitly state why
  no user documentation is needed.
- Every build, test, workflow, localization, or release process change should
  update the matching developer or release guide.
- Keep GitHub community-health files in `docs/` when possible so they are both
  GitHub-recognizable and part of the same documentation tree.
- Do not let generated plans, temporary scratch notes, or local agent state
  become permanent docs unless they are edited into a stable guide.

## Backlog

High value:

- Add screenshots or short screen recordings for the menu bar, dashboard,
  preferences, and Actives cleanup flows once the visual surface stabilizes.
- Add issue templates for bug reports and feature requests so reports collect
  the diagnostics listed in [SUPPORT.md](SUPPORT.md).
- Add a short code ownership map when module ownership becomes broader than the
  current `MacActivityApp` and `MacActivityCore` split.
- Add a troubleshooting section for release artifacts after Developer ID signing
  and notarization are fully configured.

Lower priority:

- Add a style guide only after repeated documentation review issues appear.
- Add a public documentation website only after the app has enough user-facing
  surface to justify docs beyond GitHub Markdown.
