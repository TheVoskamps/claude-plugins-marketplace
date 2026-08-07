---
name: presence-gate-on-a-normalized-document
description: a "did the operator write this key?" gate must read the RAW inputs, never the merged/normalized document — and the suite must feed the gate the same document production does, or it stays green while the real launcher lets the config through
metadata:
  type: project
---

claude-vm PR #243 / issue #135 round 3. A bake-tier gate asked
`has("copy")` of `MERGED_BAKE`. `.env.copy` had just been added to
`CLAUDE_VM_LIST_KEYS`, so the merge unioned it and
`claude_vm_prune_empty_skeleton` deleted it (and the `env:` map holding
it) when it resolved to empty — the prune's *stated purpose* being that a
consumer must not read presence off a merged document. A valueless
`copy:` therefore launched and built an image. Every non-empty spelling
aborted correctly, so the bug was invisible except on the one spelling
the gate was written for.

**Why:** two designs were wired together without either noticing —
"normalize away the difference between absent and empty" and "abort
because the operator wrote something empty". The tell is a *presence*
predicate (`has`, `in`, key-exists) applied to a document that some
earlier stage rewrites.

**How to apply:**

- When a gate's question is "what did the operator WRITE?", give it the
  raw inputs (both layers — global and repo here) alongside the merged
  document. Do not exempt the key from the normalizer: that leaves the
  "configured empty looks configured" trap for the next reader and
  changes behavior for unrelated keys.
- Ask the same question of every sibling presence gate, then *measure*
  the answer instead of reasoning it. `claude_vm_mount_mode_entries`
  survives because `mode:` sits inside a list ELEMENT the prune cannot
  reach — true, but only provable by running the real merge.
- Distinguish presence gates from **value** gates before sweeping.
  `claude_vm_check_plugin_key_placement` uses `!= null`, so a valueless
  misplaced key is ignored by design and by construction; it is not the
  same defect and "fixing" it is a contract change.
- The green suite is part of the defect: it called the gate on
  hand-written fixtures the launcher never produces. Route the whole
  battery through the real transform in the caller's own argument shape,
  and keep a negative control — running the new suite against
  `git show HEAD:<lib>` should fail exactly the cases the fix adds (6 of
  540 here). See [[slice-the-caller-to-prove-a-guard-is-wired]]: driving
  the real launcher with the offending config, plus the pre-fix launcher
  as a control, is what proves the wiring and reproduces the reviewer's
  real-run finding without booting a VM.
