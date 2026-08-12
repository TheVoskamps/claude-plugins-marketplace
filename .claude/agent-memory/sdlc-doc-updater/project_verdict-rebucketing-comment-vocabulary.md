---
name: verdict-rebucketing-comment-vocabulary
description: A permission-gate PR that MOVES a whole bucket (ask -> defer) falsifies the package's comment VOCABULARY, not just the arms it edited — sweep every file for "fail-closed ASK" and grade tier-summary headers
metadata:
  type: project
---

A gate PR that rebuckets a residual (#262 moved the ask-default to
defer) leaves far more doc residue than a classifier PR, and the residue
is uniform: the phrase **"fail-closed ASK"** and its relatives
("escalates to a human", "costs one click", "→ ASK", "denies/asks",
"never defers") were the package's whole vocabulary for *withholding an
allow*. Every occurrence is a bucket claim, and the ones that go false
are the ones naming a bucket the round moved.

**Why:** the developer edits the arms it changed and renames the helpers
it touched (`cdInvalidAsk` → `cdInvalidDefer`, `credentialedRedirectAsk`
→ `credentialedRedirectVerdict`) — and stops there. On #262 that left
~35 false comment claims, including a whole file NOT in the PR diff
(`classify_gh_aliases.go`, which describes the unrecognized-command
floor six times) and every **tier-summary header**: `classifyGh`'s
DENY/ASK/ALLOW list, `classifyGhAPI`'s per-endpoint list,
`classifySimpleCommand`'s numbered precedence list, `classifyGhAPIREST`'s
Deviation 1/2 list, and the `classifyAws`/`classifyGit` headers. A
summary list at the top of a function is where a tier rots, because
nobody rereads it when an arm below changes.

**How to apply:**

- Grep the WHOLE package (not the diff) for
  `fail-closed\|fail closed\|fails closed\|never defer` plus a
  case-sensitive `ASK`, and grade every hit against the arm it
  describes. Slurp comment BLOCKS, since the phrase wraps.
- Enumerate the surviving hard-ask tier mechanically —
  `grep -n "ask(" *.go | grep -v _test` — and check the README's
  "the whole tier is" bullet against that list. On #262 the 11 sites
  matched exactly: publish verbs, forced pushes, credential reads.
- Distinguish a bucket claim from a *shape* claim. "This is the same
  whitelist shape `ghAuthStatusEscalates` holds" survives; "the same
  fail-closed posture" does not, once the two land in different tiers.
- A "counterfactual" bucket ("treated as contained rather than asking")
  is a claim too — say what the alternative verdict actually is.
- Probe the residual rows rather than reasoning: `rm -rf build`,
  `gh co 1`, `aws s3 rm`, `git remote add`, an unpinnable redirect all
  DEFER; `git show HEAD:f > /tmp/x.md`, a `.git/` redirect and a
  `updateIssue` graphql mutation DENY; `gh auth token`,
  `git push --force`, `aws sts get-session-token` ASK.
- The evolution log is a second probe channel now: with
  `PERMISSION_GATE_LOG=<path>`, ask/deny/defer each append a record, but
  `operation` and `analysis` are EMPTY for a bare `deferToPipeline`
  (measured: `less README.md`). Any prose saying "every record carries
  the analysis" is the blanket-predicate defect —
  [[feedback_no-blanket-predicate-over-a-list]].
- Rebuild the three binaries afterwards
  ([[project_permgate-go-comment-edits-need-binary-rebuild]]).

Leftover for a fixer, not a doc pass: `ghUnmodelledFlagAsk` still returns
a `deferJudgment`, so the name outlived its bucket where two sibling
helpers were renamed. Flag it; do not rename it from a doc pass.
