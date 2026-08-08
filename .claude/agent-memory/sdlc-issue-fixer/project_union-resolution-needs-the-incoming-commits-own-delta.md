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

**The fifth case resolves to `git rebase --skip`: main already made the
incoming commit's change independently.** On PR #243 the branch's
terminal `Curate agent memory` commit did exactly one thing — split a
fused index line back into two bullets — and main's own curation pass
had split the same line. The delta read showed the one `-`/`+` pair;
`git show :2:<file> | grep` on the *ours* stage showed both bullets
already separate, so every line of the incoming side was either stale
text main had revised or a change main had already landed. Resolving
"ours" leaves an empty commit, so skip it rather than committing a
no-op. Grep the ours stage before concluding this, not the working
file — the working file still carries the markers, and the branch's own
earlier commits (already replayed) may be the reason ours looks
complete.

**How to apply:** on every conflicted rebase step, before editing the
file. It costs one `git show` per conflicted commit. Pair it with the
end-to-end check afterward, and run that check **in both directions**,
per conflicted file: `git diff origin/main HEAD -- <f>` must reproduce
the branch's own `git diff <old-base> <old-head> -- <f>` numstat, and
`git diff <old-head> HEAD -- <f>` must reproduce main's
`git diff <old-base> origin/main -- <f>` numstat. Tag `<old-head>`
before the rebase so it survives the force-push. One direction alone
proves only that one side landed.

An exact match on both sides is the proof. A mismatch is a *pointer*,
not automatically a defect — on PR #232 the pr-reviewer index came out
11/2 where main's own delta was 12/3, and the missing add/delete pair
was the single line whose branch-side revision is a strict superset of
main's (main backticked `git show <sha>:<file>`; the branch backticked
that *and* `git archive HEAD`), so main's edit survives inside the
branch's text. Print the three versions of that line — base, main,
result — and classify the pair as subsumed-superset or as a genuine
two-sided merge you wrote by hand. A pair you cannot classify that way
is a lost edit. Sibling rebase facts:
[[rebase-absorbs-an-identical-version-bump]],
[[git-status-cannot-see-main-staleness]],
[[rebase-continue-editor-gate]].
