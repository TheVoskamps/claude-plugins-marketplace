---
name: docs-locality-packaging-vs-hook-event
description: Two separate verified-facts docs in this repo's docs/ — plugin packaging system vs. hook EVENT runtime behavior — don't conflate them
metadata:
  type: project
---

This repo maintains `docs/plugin-authoring-constraints.md` (facts about
the Claude Code plugin **packaging** system: file sandboxing, skill
namespacing, `dependencies`, compaction caps, `bin/` PATH) and, as of
issue #115/PR #119, a sibling `docs/hook-event-notes.md` (facts about
individual hook **event** runtime behavior — e.g. `InstructionsLoaded`
is observe-only, only `systemMessage` JSON stdout reaches the user,
`load_reason` has multiple values). Both are "verified" docs citing
official Claude Code docs as their source, with the same "line cites
are pointers, re-verify on doc revisions" caveat style.

**Why:** a hook-event behavior fact (e.g. "X hook fires once per file,
not once per session") is true for any `settings.json` hook registered
for that event, with or without a plugin involved — it doesn't belong
in the plugin-packaging-constraints doc even if first discovered while
building a plugin. `hook-event-notes.md` is structured as a per-event
lessons-learned log (one `##` section per hook event) so future plugins
(issue #116 will add `UserPromptExpansion` / `PreToolUse`-matcher-
`Skill` notes) append sections rather than growing a numbered list that
mixes concerns.

**How to apply:** when documenting a newly-discovered Claude Code
behavior fact from building a plugin, ask whether the fact is about the
*plugin packaging system* (→ `plugin-authoring-constraints.md`,
numbered list) or about a *hook event's runtime behavior* (→
`hook-event-notes.md`, per-event `##` section). Cross-reference the
demonstrating plugin's README in both directions when applicable.
