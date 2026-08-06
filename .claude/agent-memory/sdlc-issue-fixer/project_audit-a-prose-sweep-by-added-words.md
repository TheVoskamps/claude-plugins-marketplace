---
name: audit-a-prose-sweep-by-added-words
description: a "delete X from every comment" sweep breaks prose exactly where the removed token was the head of a noun phrase; find those by pairing removed/added hunks and keeping only the ones where the sweep ADDED words, then re-read comment blocks JOINED
metadata:
  type: project
---

A mechanical sweep over prose ("remove every issue reference from the
Go comments") produces two very different kinds of hunk, and only one
of them can be wrong:

- **Pure deletion** — `foo (#125). Bar` → `foo. Bar`. Safe by
  construction; there are hundreds of these and reading them is waste.
- **Substitution** — the removed token was load-bearing (the head of a
  noun phrase, the subject of the sentence, the thing closing a
  parenthetical), so the sweeper had to put *something* in its place.
  Every artifact lives here.

**Why:** on PR #208 (issue #193) the sweep touched 604 ref-bearing
comment lines across 24 files. Two separate audits — a doc-updater's
and a pr-reviewer's — each found artifacts the other missed, and a
third round still found five more. Reading all 470 ref-bearing hunks
is unaffordable; reading the ~212 where words were *added* is not, and
it is where 100% of the artifacts were.

**How to apply:** two passes, both cheap, both scriptable (I kept the
scripts under `.claude/tmp/`; rewrite them, they are ~40 lines each):

1. `git show -U0 <sweep-sha> -- <dir>` and pair each run of `-` lines
   with the `+` lines that replaced it. Join each side into one string
   (the hunks are wrapped prose, so a phrase spans lines). Keep the
   pair only if the removed side matched `#\d+` **and** the added side
   contains a word absent from the removed side. Read those.
2. Independently, re-extract every comment block in the current tree,
   join it with the wraps closed up, and grep the joined text for
   dangling-reference shapes: `\bFix \d`, `\bdecision \d`, `\brow \d`,
   `\bcase \(\w\)`, `, prefix\)`, `\bbefore it\b`, a `which` with no
   verb after it. Both passes must come back clean.

The five artifacts this found all had the same shape — the removed
`#N` was the head of its phrase. `"the former isGitConfigPath <ref>
rule"` became `"…check, which / rule to the whole .git/ tree"`;
`"…bundled-skills tree, <ref>)"` became `"…tree, / prefix)"`;
`"before <ref> allowlisted it"` became `"before it / allowlisted it"`;
and `"<ref> Fix 2"` became a bare `"Fix 2"` naming a fix list that
nothing identifies.

**CORRECTED (2026-08-01, PR #208 round 5): do not turn this audit into
a regression guard.** An earlier revision of this memory advised
widening a `#\d+` test to joined comment blocks. Edwin approved that
test in error and had issue #193 rewritten to forbid it outright — see
[[no-source-lint-meta-tests]]. The joined-block *reading* above stays
correct as an audit technique; what must not exist is a `go test` (or
any substitute mechanism) that greps the package's own comments. The
sweep is judged by reading, and nothing enforces it afterwards.

**A second artifact lives in the same hunks: wrap raggedness.** When the
sweeper substituted longer words it re-wrapped only the lines it
touched, leaving a short line in the middle of a paragraph. The content
is *correct*, so none of the grammar shapes above finds it; a reviewer
reads it as sloppiness in a security-relevant comment header and files
it (PR #231 round 4 did, naming two sites and asking for the rest).

The reliable test is not "is this line short" — a blanket short-line
scan over every line a PR added is nearly all false positives, because
code lines are short by nature and prose here legitimately breaks early
before a long inline code span or a path. The test is: **would the
first word of the next line have fitted on this one, at the file's own
width?** Apply it only inside the sweep's own substitution hunks; a
whole-file re-wrap is churn and buries the real change. Deriving that
hunk list from `git show <sweep-sha>` (both sweep commits, not just the
one the reviewer named) took one read each and was the whole scope.

**The prose you write while fixing this is in the same class.** My
first draft of the new operator diagnostic — six `echo` lines — came
out ragged, i.e. I committed the defect I was fixing, in the same
commit. Print the message and look at it before moving on. In this repo
a diagnostic line interpolates constants (`$CLAUDE_VM_GUEST_MOUNT_ROOT`
→ `/mnt`), so the *source* lines are what get wrapped evenly and some
runtime raggedness is unavoidable and conventional here.

See also [[sweep-sibling-agent-guards]] for the other half of this
lesson — sweeping a rule's exception clause, not just its headline.
