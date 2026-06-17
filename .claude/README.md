# Claude Code Configuration

Claude Code project-specific items live under `.claude/plugins/mac-activity/`.

Shared agent skills live in `.agents/skills/` and are linked into the Claude
plugin so there is one source of truth for PR workflows.

## Skills

Claude Code discovers the linked skills through the plugin namespace:

- `mac-activity:create-pr`
- `mac-activity:pr-readiness-check`

The `SKILL.md` frontmatter names stay unprefixed (`create-pr`,
`pr-readiness-check`) because Claude validates them against the linked folder
names. The plugin provides the `mac-activity:` namespace.

The links require git symlink support. On Windows, use WSL or enable Developer
Mode and `git config core.symlinks true` before checkout.
