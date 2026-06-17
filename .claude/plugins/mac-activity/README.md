# MacActivity Claude Code Plugin

Claude Code loads project skills from this plugin with the `mac-activity:`
namespace.

Shared skill sources live in `.agents/skills/`. Entries under
`.claude/plugins/mac-activity/skills/` should be symlinks to those shared
sources unless a Claude-only override is intentionally needed.

Keep each `SKILL.md` frontmatter `name` equal to the skill folder name, without
the `mac-activity:` prefix. Claude validates names before applying plugin
namespacing.

```text
.claude/plugins/mac-activity/
├── .claude-plugin/
│   ├── marketplace.json
│   └── plugin.json
├── skills/
│   ├── create-pr -> ../../../../.agents/skills/create-pr
│   ├── create-release -> ../../../../.agents/skills/create-release
│   └── pr-readiness-check -> ../../../../.agents/skills/pr-readiness-check
└── README.md
```

Do not edit through the symlink path. Edit `.agents/skills/<name>/SKILL.md`.
