---
name: vendor-hook-claims-are-fetchable
description: A "Claude Code does X with this hook field" claim is settled by curl-ing the docs' .md source, not left as the developer's unlabelled assertion
metadata:
  type: feedback
---

A PR's prose about **harness** behavior — what Claude Code does with a
`permissionDecision` value, which events honor which field — looks
unverifiable from inside the repo and so survives every review pass as
a flat assertion. It is one command away:

```bash
curl -sL https://code.claude.com/docs/en/hooks.md -o <scratchpad>/hooks.md
```

The `.md` suffix returns the whole page as greppable text; scraping
the rendered HTML returns one 1MB line and is useless. Save it in the
harness scratchpad — a read back from bare `/tmp` is refused by the
gate — and grep it.

**Why:** on #271 (PR #272) the branch asserted, on six surfaces, that
Claude Code reads a literal `"defer"` as "pause the tool call for
later resumption". True, and the docs' *Defer a tool call for later*
section carried two scoping conditions nobody in the round had: the
value is honored **only** in non-interactive `-p` mode (an interactive
session logs a warning and ignores the hook result) and **only** on a
turn making a single tool call. Those two facts are the whole
explanation of the bug's shape — why the gate shipped the literal for
months while the human's own session was fine, and why subagents died
"within a few requests" rather than on the first one. Neither was
recoverable from the repo, and both belong in the doc.

**How to apply:** whenever a diff's prose says "Claude Code does X",
fetch and grep before letting it stand. Do not downgrade it to a hedge
— check it. The repo home for what comes back is
`docs/hook-event-notes.md` (per-event, doc-verified), whose preamble
now carries this fetch recipe; a plugin's own README carries the local
consequence and points there. See
[[project_guardrails-permgate-docs-locality]].
