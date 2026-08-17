---
name: claude-vm-guest-surface-only-claims
description: Any claude-vm PR that copies more host state into the guest falsifies the unqualified "the guest's Claude surface is defined by THESE configs ONLY" sentence, which is restated on four surfaces a settings.json grep never reaches.
metadata:
  type: project
---

`plugins/claude-vm` states, in four places, that the guest's Claude surface
comes from the claude-vm configs **only** because the host's
`~/.claude/settings.json` is never read:

- `payload/config-boot.example.yml` (the `permission_mode` / `permissions`
  block)
- `payload/config-bake.example.yml` (the marketplaces/plugins block)
- `payload/claude-vm.sh` (the settings-render call site)
- `payload/lib/config.sh` (the rendered-document key list)

Each sentence's *evidence* is about settings.json or plugins, but each
sentence's *subject* is the whole "Claude surface". So a PR that seeds any
other host `~/.claude` content into the guest — issue #108 seeded
`CLAUDE.md`, `rules/`, `agents/`, `skills/`, `keybindings.json` — leaves all
four asserting the opposite of what the guest now does, while every
`settings.json` / `never copied` grep still returns true statements.

**Why:** the false half is the noun, not the verb, so the grep that finds
these sites (`settings.json`) is not the grep that shows they are wrong.

**How to apply:** on any claude-vm PR that widens what crosses the
host→guest seam, grep `Claude surface` across `plugins/claude-vm/` and
narrow each hit to the layer it actually measures (PERMISSION surface,
PLUGIN surface), rather than checking only the surfaces the diff touched.
Two of the four are example YAML files, which no test and no doc pass
naturally opens. See [[claude-vm-config-redesign-stale-comment-classes]].
