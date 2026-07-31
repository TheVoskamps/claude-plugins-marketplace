---
name: plugin-docs-locality
description: Where to document a brand-new plugin — root README roster vs docs/plugin-authoring-constraints.md vs docs/hook-event-notes.md vs docs/plugin-migration-plan.md
metadata:
  type: project
---

When a PR adds a brand-new plugin (new `plugins/<name>/` dir + a new
entry in `.claude-plugin/marketplace.json`), the doc surfaces split
three ways:

- **Root `README.md`** "Published plugins" section is the live roster
  of record — one bullet per `marketplace.json` entry, name + one-line
  purpose. This is the one doc that reliably goes stale when a plugin
  is added, because nothing else cross-references the plugin list by
  name (verified via repo-wide grep for a plugin's own name across
  `*.md` — nothing hit except the plugin's own directory).
- **`docs/plugin-authoring-constraints.md`** is reference material for
  *authoring* plugins — durable, doc-verified facts about the plugin
  **packaging system itself** (file sandboxing, skill namespacing,
  `dependencies`, compaction caps, `bin/` on PATH — the constraints
  that feed the doc's "Patterns this marketplace uses" section). Do
  NOT put hook-EVENT behavior facts here: those are true for any
  `settings.json` hook with no plugin involved, so they are off this
  doc's charter (human explicitly redirected this on PR #119).
- **`docs/hook-event-notes.md`** is where hook-event behavior facts
  discovered while building hook plugins go (e.g. issue #115's
  `show-loaded-rules` plugin demonstrated that `InstructionsLoaded`
  is observe-only and only its `systemMessage` JSON field — not
  stdout — reaches the user). Append per-event entries there with a
  citation to the official hooks docs; cross-reference the plugin's
  own README rather than duplicating its explanation.
- **`docs/plugin-migration-plan.md`** is a **historical planning
  record** for the original skills-to-plugins migration (its "Target
  plugins (7)" table). It was already stale before this PR — later
  plugins like `guardrails`, `block-background-agents`, and
  `claude-vm` aren't in that table either. Do NOT add new plugins to
  it; it documents a plan, not the current roster.

**Why**: without this split, a doc-updater run either skips the one
doc that actually needs the new entry (README) or wastes an edit on a
frozen planning doc that predates plugins added after the migration
completed.

**How to apply**: when a PR's diff is "new plugin, no changes to
existing plugins", check root README's roster for the missing entry
first. Then route any newly demonstrated platform fact by kind:
plugin-packaging-system fact → `plugin-authoring-constraints.md`;
hook-event behavior fact → `docs/hook-event-notes.md`. Never touch
`plugin-migration-plan.md` for a new-plugin PR.
