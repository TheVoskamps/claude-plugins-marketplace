---
name: verdict-rebucketing-comment-vocabulary
description: A permission-gate PR that MOVES a whole bucket (ask -> defer) falsifies the package's comment VOCABULARY, not just the arms it edited — sweep every file for "fail-closed ASK" and grade tier-summary headers
metadata:
  type: project
---

A gate PR that rebuckets a residual (in #262 the gate's then-standing
ask-default became defer) leaves far more doc residue than a classifier
PR, and the residue is uniform: the phrase **"fail-closed ASK"** and its relatives
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
  "the whole tier is" bullet against that list. On #262 the sites
  matched exactly: publish verbs, forced pushes, credential reads AND
  credential mints (`aws sts assume-role`, `iam create-access-key` —
  added late in that PR, and the README bullet, `main.go`'s package
  header and `decision.go`'s `BucketAsk` comment each name the tier
  separately, so all three take the widening).
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
  [[feedback_no-blanket-predicate-over-a-list]]. An unrecognized
  PROGRAM is not one of the empty rows: `npm test` reaches
  `bash:no-specific-rule`, a `deferJudgment`, and that label loses to
  any other defer analysis on the same line.
- Rebuild the three binaries afterwards
  ([[project_permgate-go-comment-edits-need-binary-rebuild]]).

The rename class runs one level past the helpers: TEST NAMES and their
doc comments assert buckets too, and a rebucketing round leaves a
`TestFooAsks` whose body checks `BucketDefer`. Derive the list rather
than eyeballing it — parse each `func Test…` body for its `Bucket*`
tokens and diff that set against the bucket word in the name — since a
name like `TestContainmentNoRepoNeverAllows` legitimately claims the
bucket it does NOT assert.

The test sweep needs a SECOND pass after the fixer's: a round that
renames every `TestFooAsks` still leaves the prose in the block above
it, and the doc comment is where the tier claim actually lives. Run the
same parse against the DOC COMMENT, not the name — for each `func
Test…`, collect the body's `Bucket*` tokens and print the block above
whenever it says `ASK`/`asks` and the body never checks `BucketAsk`.
That found 20 blocks the two prior rounds had left on #262, in ten
files. Three shapes survive the filter and are NOT defects: a
historical sentence ("#262 moved it from ASK to…"), a negative claim
("must not ASK" — a defer satisfies it), and a hard-ask row that really
does still ask. Everything else — file-level suite headers most of all
— is false. Two claims in that harvest were not bucket words at all and
matter more: a blanket "every log record carries the analysis" (false
for a bare `deferToPipeline`) and "the reason names the fields so the
HUMAN sees them" (`emitDecision` blanks a defer's reason on the wire —
the reason reaches the evolution log only).

A THIRD pass finds a shape both earlier ones filter out: the
illustrative example inside a **test HELPER's** doc comment. `wantReason`
in `classify_bash_test.go` justified itself with "a row asserting a
publish ASK keeps passing after it starts earning a no-repo-context ASK
instead" — a helper, so no `func Test…` parse reaches it, and the
sentence is about a *hypothetical* row, so no body has a `Bucket*` token
to compare against. It went false the moment the no-repo-context arm
became a `deferJudgment`. Grep helper and file-header comments for a
named ARM plus a bucket word, and re-check the arm's current return.

The same round's other leftover: a numbered precedence list in a
function header whose LAST item is the residual ("7. Otherwise DEFER to
the normal pipeline") stays literally true when the residual gains an
operation label, while ceasing to describe what the arm now does. Reread
the header list of any function whose residual the round touched, even
when no word in it is false.

A FOURTH pass has its own signature: the cost sentence. Grep `click`
(not a bucket word) across the package and grade each hit — a
"therefore costs one human click, not a silent publish" survives in a
FILE-HEADER property list long after the function it summarises was
renamed to `…Defer` and its own doc comment corrected. On #262 that
shape appeared in `classify_gh_files.go`'s `#225 properties` list and
twice more in the deny arms, where "the cost of a false deny is one
human click" contradicts `decision.go`'s own `BucketDeny` definition (a
deny teaches the model, it never prompts) — grep `false deny` too.

The same pass turns up the one defect class that is NOT vocabulary: a
test whose doc explains WHY it passes, wrongly. `classifyCmd`'s cwd is
`/tmp`, so every path-bearing row lands on the no-repo-context residual
— and `TestProcessSubstitutionDoesNotPanic_5`'s "procsubst is not
statically resolvable, so it must NOT ride the allow track" is refuted
by replaying the same six rows with a REAL repo cwd, where three of
them ALLOW (the gate descends into the inner command; `cat <(ls /etc)`
denies on the inner operand). Behaviour right, stated reason false, no
test fails. Whenever a test doc gives a mechanism for a bucket
assertion, replay its rows through the binary with repo context before
letting the sentence stand.

The `ghUnmodelledFlagAsk` leftover this note flagged for a fixer was
renamed to `ghUnmodelledFlagDefer` in #262's fix round, alongside the
sibling renames (`cdInvalidAsk` → `cdInvalidDefer`,
`credentialedRedirectAsk` → `credentialedRedirectVerdict`). The rule
stands: flag such a rename from a doc pass, do not perform it.
