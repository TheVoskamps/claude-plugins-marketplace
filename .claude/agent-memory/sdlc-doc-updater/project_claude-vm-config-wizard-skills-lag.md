---
name: claude-vm-config-wizard-skills-lag
description: claude-vm feature PRs update payload/README.md + skills/claude-vm/SKILL.md thoroughly but leave the two config-WIZARD skills (claude-vm-config-global / -repo) stale, including key-placement facts that are now launch-aborting.
metadata:
  type: project
---

On issue #107 (config-driven marketplaces + plugins) the developer's doc pass
covered `payload/README.md`, `skills/claude-vm/SKILL.md`, and both
`config-*.example.yml` in depth — and touched neither
`skills/claude-vm-config-global/SKILL.md` nor
`skills/claude-vm-config-repo/SKILL.md`. Those two wizard skills still:

- placed `claude.marketplaces` / `claude.plugins.bake` in the **boot** template
  they instruct the model to WRITE, which #107 made a launch-aborting
  misplacement (the wizard would have produced a config that cannot launch);
- carried "the consumer lands in a #39 sibling slice" claims for keys that had
  since gained consumers (`packages`/`apt_sources` in #105/#106,
  plugins in #107). Only `github.auth` still lacks one.

**Why:** the wizard skills are one directory over from the skill the developer
edits, and they duplicate the key tables/templates rather than referencing
them — so nothing forces them to move together. This is the same
"comments elsewhere in the same plugin don't get updated" pattern as
[[claude-vm-config-redesign-stale-comment-classes]], one level up at the
doc-file granularity.

**How to apply:** after ANY claude-vm config-schema change, grep
`plugins/claude-vm/skills/claude-vm-config-{global,repo}/SKILL.md` for the
changed key names AND for `#39`/`sibling slice`/`schema + merge only`. Check
three surfaces in each: the key table's bake/boot **file** column, the YAML
templates the skill writes verbatim, and the "Hard constraints" placement
bullet. Also check `payload/README.md`'s helper-function list — new
`lib/config.sh` helpers and changed signatures land there and were again not
updated by the developer.
