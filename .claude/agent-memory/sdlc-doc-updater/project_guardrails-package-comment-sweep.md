---
name: guardrails-package-comment-sweep
description: permission-gate duplicates containment-behavior doc comments per entry point; a doc sweep after a containment-rule change must grep the whole directory, not trust the developer's call-site edits alone
metadata:
  type: project
---

During the #130 doc-updater run (PR #138, "Allow read access to
primary clone / shared git dir paths"), the developer's own commit
(18c8b21) updated the containment-decision logic but left several
function-level doc comments elsewhere in the `permission-gate`
directory still describing the pre-#130 behavior — a non-`.git/`
primary-clone/worktree-escape read asserted as ASK, when the new
behavior is contained/allow (a `.git/`-tree read still denies; writes
are unaffected).

The stale comments were not confined to the file the developer edited
for the behavior change — they were duplicated across
`classify_files.go`, `classify_inrepo_write.go`, and
`readonly_util.go`, each carrying its own paraphrase of the same
containment rule at its own call site. This mirrors the pattern in
[[project_guardrails-permgate-docs-locality]] (README duplicating
Go-comment content) but one level deeper: the doc comments duplicate
*each other* across files within the same package.

**How to apply:** after any change to `permission-gate`'s containment
or classification rules, don't stop at reviewing the diff's own doc
comments. Run `grep -rn` across the whole
`plugins/guardrails/hooks/permission-gate/` directory for the old
behavior's keywords (e.g. the specific verb/outcome pair being
changed, like "ASK" vs "allow" for a given read/write case) to find
every duplicated description, not just the one in the changed file.
The developer's own call-site edit is necessary but not sufficient
evidence the sweep is complete.
