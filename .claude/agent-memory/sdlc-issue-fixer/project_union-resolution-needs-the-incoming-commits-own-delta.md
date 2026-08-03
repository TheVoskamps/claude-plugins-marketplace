---
name: union-resolution-needs-the-incoming-commits-own-delta
description: Resolving an append-only index (MEMORY.md) conflict by unioning both sides silently reverts the other side's in-place revisions; read the incoming commit's own delta with `git show <sha> -- <file>` to learn which lines it actually meant to change — and merge, rather than pick, the lines both sides revised
metadata:
  type: project
---

When a rebase conflicts on an append-only list file — an agent-memory
`MEMORY.md` index is the recurring case — do **not** resolve by pasting
both sides together. First run `git show <incoming-sha> -- <file>` and
read what that one commit actually changed. Take the incoming side only
for the lines it touched; take `HEAD`'s (main's) text for every other
line in the hunk.

**Why:** git's conflict hunk is a *region*, not a change set. Both
sides append to the same tail and revise entries in place, so one
region routinely mixes three different things: lines only main added,
lines only the branch added, and one line both sides rewrote from the
same ancestor. Union-pasting keeps main's additions but re-installs the
branch's stale copy of every line main revised — a silent revert with
no marker and no diff line to notice missing. Concretely, on PR #220 a
single conflict region in `sdlc-pr-reviewer/MEMORY.md` held: three
entries main had newly added, two entries main had *retitled and
rewritten* (`GraphQL relationship read gate-blocked` →
`GraphQL reads pass the gate now`; a one-clause
`Guardrails binary verification` → a four-clause one), and exactly one
line the incoming commit meant to change. `git show 1f6178b -- <file>`
showed a one-line diff, which is what made the other five obviously
main's to keep. Reading the hunk alone could not have told them apart —
both sides' text looked equally deliberate.

The same read settles the deletion case: a terminal curation commit
that drops an index entry conflicts against main's *additions* to the
same tail. Its own delta shows one removed line, so main's new entries
stay and only that one goes.

**The fourth case needs a real merge, not a pick: both sides revised
the same line.** The delta read identifies it — the incoming commit's
diff shows a `-`/`+` pair on a line main also rewrote — and neither
side's text is correct alone. Write one line carrying both revisions'
content. On PR #217 round 4 the `Rebase absorbs an identical version
bump` index entry had main appending
`(differing values conflict loudly — take the greater, don't re-bump)`
while the branch replaced the tail clause with
`can fire twice in one round, so check git diff --stat origin/main HEAD`;
the resolution keeps the branch's replacement *and* main's parenthetical,
because the entry's body file (auto-merged, so both paragraphs survived)
documents both facts. Taking either side alone would have left the index
line describing less than the file it points at.

**How to apply:** on every conflicted rebase step, before editing the
file. It costs one `git show` per conflicted commit. Pair it with the
end-to-end check afterward — `git diff origin/main..HEAD --stat` should
match the pre-rebase `git diff <old-base>..<old-head> --stat` file-for-
file and line-for-line; a changed count there means a resolution
dropped or duplicated something. Sibling rebase facts:
[[rebase-absorbs-an-identical-version-bump]],
[[git-status-cannot-see-main-staleness]],
[[rebase-continue-editor-gate]].
