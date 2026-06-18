# Agent Skills

Shared project skills live in `.agents/skills`.

- Add project-wide skills under `.agents/skills/<name>/SKILL.md`.
- Keep skills short and runnable with standard repository tools.
- PR-related skills must use `.github/pull_request_template.md` and
  `.github/pull_request_title_conventions.md` as their source of truth.
- Claude Code loads these skills through `.claude/plugins/mac-activity/skills/`
  symlinks. Edit the shared `.agents/skills` source, not the linked copy.
