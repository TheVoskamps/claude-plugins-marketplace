---
name: pr-review-pipeline
description: The sdlc PR review pipeline — resolve the issue set, spawn a theorem-generator, fan out one theorem-disprover per theorem in parallel, fan out one counterexample-verifier per disproved theorem, derive severities and verdicts mechanically, and post a single argued review. Runs in the main session, invoked by /sdlc:git-review-pr and by the /sdlc:orchestrate loop; not invoked from the user's slash menu.
user-invocable: false
---

# PR Review Pipeline

This is the `sdlc` review procedure. It replaces the reviewer agent
that used to hold it: review is now a **pipeline** — a theorem
generator, a parallel fan-out of disprovers, a second parallel fan-out
of verifiers over what the disprovers broke, and a mechanical
synthesis — rather than one agent reading a diff against a checklist.

The verification stage is what stands between a disprover's mistake
and a filed finding. A counterexample nobody re-checked is one agent's
word: the quote can be misread, the excerpt can be cut against its own
context, the consequence can be overstated. So every `DISPROVED`
theorem gets a second, adversarial reader whose brief is to reject the
counterexample, and only a counterexample that survives that becomes a
finding.

## Run this in the main session

You run this pipeline **in the main session**, never inside a
subagent. A subagent cannot spawn subagents, and the two fan-outs in
steps 4 and 5 are the whole design, so a pipeline run from inside an
agent would collapse to a single reader — exactly the shape this
replaced.

Each entry path is a main-session path:

- `/sdlc:git-review-pr <PR>` — the standalone review.
- The `/sdlc:orchestrate` loop, after each `doc-updater` pass.

You write no code and you post exactly one review. You never commit,
never push, and never edit a file: the pipeline is strictly
non-mutating on the branch. The agents it spawns are non-mutating too
— `theorem-generator`, `theorem-disprover`, and
`counterexample-verifier` each declare no `memory:`, so there is no
memory capture to commit and nothing for `agent-memory-scrubber` to
curate from this pipeline.

## Why the diff never lands in your context

You do not fetch the PR diff. The generator reads it in its own
worktree and returns a theorem list; each disprover reads only the
region its own theorem points at, and each verifier only the region
the counterexample it was handed points at. What reaches you is the
theorem list, the per-theorem verdicts, the verification verdicts, and
the change counts you read from `gh pr view`. That is deliberate: the
main session's job here is routing and derivation, and a diff in
context would tempt it into re-reviewing by hand — an opinion nothing
asked for.

## Inputs

The pipeline takes double-dash parameters. One vocabulary serves every
entry path: the orchestrator writes exactly these tokens when it
invokes the pipeline, and a standalone invocation passes the same
flags.

- `--pr <N>` (required) — the pull request to review. With no `--pr`,
  stop and report that the caller named no PR rather than guessing
  one.
- `--issues <N…>` (optional) — the issue numbers this PR closes,
  space- or comma-separated, each with or without a leading `#`. This
  is the **claim**, not the answer: step 2 reconciles it against the
  branch. Absent, step 2 takes the claim from the PR body instead —
  the standalone path.
- `--branch <name>` (optional) — the PR's head branch. Absent, step 2
  reads it from GitHub.
- `--generator <agent-name>` (optional) — which `theorem-generator`
  definition to spawn, one of `theorem-generator` (the default),
  `theorem-generator-high`, or `theorem-generator-xhigh`. The
  orchestrator picks one per its selection rule (see the
  `/sdlc:orchestrate` skill → "Picking a generator tier"); the
  standalone path passes none and gets the default.

No other parameter exists. In particular there is no effort or model
parameter for the generator: its tier IS the definition named by
`--generator`, and the generation instructions it runs are tier-blind.

## Read repo config first

Read this repo's `.claude/rules/repo-config.md` with a lightweight
**inline** parse of just the front-matter field below — not the full
reader contract in the `issues` plugin's `skills/lib/repo-config.md`.
That lib file lives inside the `issues` plugin, and plugins are
file-sandboxed (a bare `Read` from an `sdlc` skill cannot resolve a
path inside another plugin's directory — see
`docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). `sdlc` no longer bundles its own copy of that lib
(`plugins/sdlc/skills/lib/repo-config.md` was deleted), so do not
attempt to `Read` it by any bare or qualified path.

You need only this field from the file:

- `issue-link-prefix` (string, e.g. `"#"` for GitHub or `"SET-"` for
  Jira) — the prefix used in `References:` trailers (see step 2
  below). This is an **issue-tracker** concern, independent of the PR
  mechanics: `github-prs:pr-review-submit` and
  `github-prs:pr-closing-issues` read no repo-config at all — they are
  GitHub-only by design — and `git-tools:git-issues-from-branch` reads
  `issue-branch-naming-prefix` internally, so you do not resolve
  `source-control`, `default-issue-source-branch`,
  `default-pr-target-branch`, or `issue-branch-naming-prefix`
  yourself.

If `.claude/rules/repo-config.md` is missing, abort with: "This repo
has no `.claude/rules/repo-config.md`. Run `/repo-config` to create
one." (the same wording the full reader contract uses for its "File
missing" case, so the namespace's abort messages stay consistent even
though this pipeline doesn't consume the whole contract).

In the rest of this document, `<link-prefix>` means the resolved
value.

## Workflow

### 1. Read the PR's shape

```bash
gh pr view <PR> --json headRefName,headRefOid,body,changedFiles,additions,deletions
```

`changedFiles`, `additions`, and `deletions` are the change counts the
review body reports. `headRefName` and `body` feed step 2;
`headRefOid` feeds step 4's single fetch and every disprover's and
verifier's brief. Do not fetch the diff — see "Why the diff never
lands in your context" above.

### 2. Identify the issue set this PR is for

A PR delivers a **batch** — an ordered set of issues implemented on
one branch — and a batch of one is the ordinary single-issue PR.

- **Your claim** is `--issues`, when the caller supplied it. Run
  standalone on a bare `--pr` — the `/sdlc:git-review-pr` path —
  there is no issue set to take it from, so get it from
  `/github-prs:pr-closing-issues <PR>`, the one skill that reads a PR
  body's closing lines. Never scan the body for them yourself.
- **Reconcile the claim against the branch.** Invoke
  `/git-tools:git-issues-from-branch <headRefName> <claim…>` — the one
  skill that parses a branch name and the one place the global
  issue-to-branch rule in `rules/git-workflow.md` → "Issue references"
  is applied. Never parse a branch name and never re-derive the
  resolution yourself. **The set you review against is the resolved
  set it reports.**

The lists it reports alongside the resolved set are findings rather
than members:

- **A claimed issue the skill places outside the branch's set is a
  finding, not a member.** `/github-prs:pr-create` and
  `/github-prs:pr-link-issue` refuse to write a closing line for one,
  but a hand-edited body can carry it, and merging the PR would then
  auto-close an issue this branch never delivered — the auto-close
  hazard the closing-keyword rule exists to prevent. Never fold it
  into the set you review against. Grade it on that consequence per
  "Findings by severity" below, and give it its own verdict line per
  "Per-issue verdicts, one overall".
- **A branch member on the skill's *not claimed* list is either a
  sanctioned deferral or a silent under-delivery, and the PR body is
  what tells them apart.** When the body names the member and says why
  it is not in this PR, that is a deferral the human already owns:
  note it as context, not a finding. When a member is simply missing
  with no explanation, that IS a finding — it is the exact failure a
  batch PR invites, and it is an unmet acceptance criterion (graded
  High per "Findings by severity" below). That member gets its own
  verdict line carrying the finding, per "Per-issue verdicts, one
  overall" below, even though the diff is not reviewed against it.

The remaining outcomes need no separate handling. On **not a
convention branch** — a human-named or `dependabot/…` branch, the
usual shape when `/sdlc:git-review-pr` hands you a bare `--pr` — the
skill resolves to your claim unchanged and reports those lists empty,
so no finding above can arise and your claim is the whole answer. On
**no safe resolution** there is no resolved set, so no member is
reviewed against, no theorems are generated, and the findings above
cover the PR between them: every claimed issue is outside the branch's
set, and every branch member is unclaimed. Post that review and stop —
there is nothing for a generator to work from.

`References:` trailers in the PR body link *other* related issues
(predecessors, follow-ups, umbrella issues, etc.) using the
`References: <link-prefix><M>` format (e.g. `References: #42` on
GitHub, `References: SET-42` on Jira). A reference with no closing
keyword before it closes nothing, so `/github-prs:pr-closing-issues`
already leaves these out — never add one to the set by hand. The
closing keywords themselves are required in the **PR body**, one line
per member, and forbidden in a **commit message**; the same words as
ordinary English prose with no adjacent issue reference are fine
anywhere and must not be flagged.

The findings above are the only ones this pipeline raises outside the
theorem list. Everything else it posts is a disproved theorem.

### 3. Spawn the theorem generator

Spawn the definition `--generator` named (default `theorem-generator`)
with the `Agent` tool, passing the resolved set from step 2 — not the
caller's claim:

```text
--pr <PR_N>
--issues <resolved_N1> <resolved_N2> …
--branch <headRefName>

Generate the theorem list per your preloaded generation skill. Report
it back in the theorem-record format that skill defines, and nothing
else.
```

Pass no tier, effort, or model in the brief. The generator's tier is
the `effort:` of the definition you spawned.

You get back a numbered theorem list. Each record carries a claim, the
member issue(s) it is tagged to, a `mechanical` / `semantic` class,
and file/region pointers. If any record is missing a field, ask the
generator to re-emit that record rather than guessing the field
yourself — you are not a source of theorems.

### 4. Fan out one disprover per theorem, in parallel

**Fetch once, here, before you spawn anything.** The k disprovers run
in k worktrees of one repo, and those worktrees share that repo's
single ref store — so k concurrent `git fetch origin` calls contend
for the same `.git`, and the loser of a lock race fails rather than
waiting. Run the fetch yourself, in this session, and confirm the ref
carries the head commit step 1 read:

```bash
git fetch origin
git rev-parse origin/<headRefName>   # must equal <headRefOid>
```

If it does not match, the branch moved between step 1 and now: re-read
the PR's shape (step 1) and restart the review from step 2 against the
new head, rather than reviewing a mix of two trees.

Then spawn one `theorem-disprover` per theorem, **all in a single
message block** so they run concurrently. One disprover per theorem is
the starting point; if missed counterexamples show up in practice, N
disprovers per theorem is a one-line change here.

Route the model by the theorem's class:

- **`mechanical`** — pass `model: haiku` on the `Agent` call. A
  grep-shaped claim is settled by running the grep, and the cheap
  model runs it as well as any other.
- **`semantic`** — pass no `model`, so the spawn uses whatever
  `theorem-disprover`'s frontmatter declares. Read the value there
  rather than restating it here.

This per-theorem routing is deliberate. A frontmatter `model:` is a
default, not a floor or a ceiling — the `Agent` tool's `model`
parameter may name a lower, higher, or equal model for a single spawn
— so `mechanical` naming haiku is an ordinary use of that parameter
for a class of theorem the design has already decided is cheap. If a
harness ever refuses to route below the declared default, the
mechanical spawn simply runs at that default: costlier, never wrong.

Each disprover's brief is one theorem and nothing more:

```text
--pr <PR_N>
--branch <headRefName>
--head-sha <headRefOid>
--fetched yes
--theorem T<k>
--claim <the claim, verbatim from the generator's record>
--issues <the member(s) the theorem is tagged to>
--class <mechanical|semantic>
--pointers <the generator's pointers, verbatim>

Try to disprove this one claim per your agent definition. Report
DISPROVED with a verbatim-quoted counterexample, a consequence
statement, and a proposed consequence class, or SURVIVED with what
you checked. Nothing else.
```

`--branch` is the same `headRefName` you passed the generator. Every
disprover needs it — each checks the head commit out in its own
worktree before settling anything — and each does so **detached**,
from `origin/<branch>`, per its agent definition. That is what makes
this fan-out possible at all: worktrees of one repo share a single ref
store and a branch can be checked out in only one of them at a time,
so an attached checkout would leave k−1 of your k disprovers dead at
`fatal: '<branch>' is already used by worktree at '…'`.

`--head-sha` and `--fetched yes` are what keep the fetch you just ran
from being run k more times: a disprover given both, and finding
`origin/<branch>` already at that SHA, checks out straight from the
ref it has. Pass them only when you really did fetch in this session —
a disprover told `--fetched yes` against a ref that is behind would
review the wrong tree, so the honest omission costs one fetch and the
dishonest claim costs the whole round.

Never merge two theorems into one brief, and never add a theorem of
your own to a brief. The one-theorem contract is what keeps a
disprover from wandering into unrelated nits.

### 5. Fan out one verifier per disproved theorem, in parallel

A `DISPROVED` report is a candidate finding, not a finding. Once
**every** disprover has returned, spawn one `counterexample-verifier`
per `DISPROVED` theorem, **all in a single message block** so they run
concurrently.

`SURVIVED` theorems spawn no verifier. There is no counterexample to
attack, and verifying survivals would double the cost of the common
case for nothing.

These kinds of `DISPROVED` report are malformed and never reach a
verifier: one whose counterexample is not a verbatim quote, and one
that asserts file topology without having run a topology command (see
"Before claiming file-topology issues" below). Re-spawn that one
disprover with the same brief rather than filing the finding on a
paraphrase or dropping it silently; if the second run is malformed
too, the theorem is unsettled — see the disposition table in step 6.
Spawning a verifier against a malformed report would waste the check
on evidence that has already failed a cheaper one.

Route the model exactly as step 4 did, by the theorem's class:
`model: haiku` on the `Agent` call for a `mechanical` theorem, no
`model` for a `semantic` one, so that spawn uses whatever
`counterexample-verifier`'s frontmatter declares. Read the value there
rather than restating it here.

You fetched in step 4 and the branch has not moved since, so pass the
same `--head-sha` and `--fetched yes` a disprover got — the same
lock-race reasoning applies to k verifiers sharing one ref store.

Each verifier's brief is one counterexample and nothing more:

```text
--pr <PR_N>
--branch <headRefName>
--head-sha <headRefOid>
--fetched yes
--theorem T<k>
--claim <the claim, verbatim from the generator's record>
--issues <the member(s) the theorem is tagged to>
--class <mechanical|semantic>
--pointers <the generator's pointers, verbatim>
--counterexample <the disprover's full DISPROVED report, verbatim>

Try to refute this one counterexample per your agent definition.
Report REFUTED with the rejection reason, or STANDS with a confirmed
or corrected consequence statement and a consequence class. Nothing
else.
```

The disprover's report is copied through **unchanged**, exactly as its
quote is copied unchanged into a finding. Never summarize it for the
verifier: a paraphrase is precisely the thing the verifier is checking
for, so paraphrasing it here would make the check meaningless.

**No retry ping-pong.** A `REFUTED` counterexample ends that theorem's
round: you do not re-spawn the disprover for another attack, and you
do not spawn a second verifier to check the refutation. One attack,
one check.

A verifier report that carries no reason, or a reason that does not
engage the counterexample it was handed, is malformed. Re-spawn that
one verifier with the same brief; if the second report is malformed
too, the finding **stands** — resolve toward filing, never toward
silently dropping a counterexample that carried verbatim evidence, and
take the consequence class from the disprover's proposal in that case.

### 6. Derive the disposition of every theorem

This step is a **derivation, not a judgment**. There is no synthesizer
agent because there is nothing left to judge: the disprover returned a
verdict on the claim, and the verifier returned a verdict on the
counterexample.

| Disprover | Verifier | Disposition |
| --- | --- | --- |
| `SURVIVED` | not spawned | **Verified** list, carrying what the disprover checked |
| `DISPROVED` | `REFUTED` | **Verified** list, with the offered counterexample and the rejection reason on the line |
| `DISPROVED` | `STANDS` | a **finding** → severity → verdict, per the chain below |
| `DISPROVED` | malformed twice (the verifier's own re-spawn path) | a **finding** → severity → verdict, per the chain below, with the consequence class taken from the disprover's proposal |
| malformed twice (the disprover's own re-spawn path) | not spawned | **could not be settled**, no severity |

"Could not be settled" and "unsettled" are the same disposition —
this last row. The long form is what the posted review body's section
is titled; "unsettled" is the shorthand this file and the report-back
tally use for it.

A standing finding is written in the format under "Findings must
quote, not paraphrase" below. Its `**Evidence:**` block is the
disprover's counterexample quote **verbatim** — you do not re-quote
the source yourself, and you never paraphrase what either agent sent.
Its severity is the transcription of the consequence class the row
above assigns it — the verifier's, or the disprover's proposal on the
verifier-malformed-twice row — per "Consequence classes are
transcribed, not graded" below, and it is tagged to the member
issue(s) the theorem carried.

A `REFUTED` theorem is **not** proved. It had one counterexample
offered against it and rejected, and its Verified line says exactly
that rather than claiming the claim was checked and held.

Then derive the verdicts per "Per-issue verdicts, one overall" and
"Verdict follows from findings" below. Every step from here to the
posted review is mechanical.

### 7. Post one review

Post via `/github-prs:pr-review-submit <PR> <verdict> <body>`, with
`<verdict>` the **overall** verdict — one of `approve`,
`request-changes`, or `comment`. The skill posts a **single** call
carrying both verdict and body — never two calls (a separate
`--comment` then `--approve` creates two notifications) — and handles
the self-review constraint (`gh` blocks `--approve` when the reviewer
is the PR author) by downgrading to an inline `--comment` carrying an
explicit `APPROVED` line.

The body carries the **full theorem list**, per "Review body" below.
Coverage is auditable that way: a reader can see every claim that was
checked, not only the ones that broke.

### 8. Clean up the spawned worktrees

Every generator, disprover, and verifier runs in its own
`isolation: worktree` worktree, and none of them ever claims the PR
branch — each checks out `origin/<branch>` detached (see their
definitions), so there is no claim to release and no local branch to
delete. What is left is the worktree *directories*, which the spawner
removes:

```bash
git worktree list
git worktree remove .claude/worktrees/<name>
```

Remove them **serially**, never in parallel — see
[Anthropic issue #48927](https://github.com/anthropics/claude-code/issues/48927)
for a parallel-cleanup data-loss bug. A round leaves one worktree per
agent it spawned: the generator, k disprovers, and one verifier per
disproved theorem, plus one more for each re-spawn. Remove them one
after another once they have all returned.

If a removal fails with `fatal: cannot remove a locked working tree`
and the lock reason matches the harness's standard end-state shape
(`claude agent agent-<hash> (pid NNNN)`), the agent has returned and
left a stale lock: `git worktree unlock <path>` then remove.

Unlock-then-remove is **not** allowed when the agent is still mid-run,
when the lock reason does not match that standard shape, or when the
worktree carries uncommitted work or unpushed commits. The last is a
data-loss case and needs human approval — though the pipeline's agents
never commit, so it should not arise from a review round. Never reach
for `git worktree remove -f`.

## The theorem contract

A theorem is a claim about this PR that the generator has already put
through the emission bar. Applying that bar is the generator's job:
the `sdlc:theorem-generation` skill → "The emission bar:
falsifiability, then stakes" owns the questions it asks, along with
which candidates they exclude and why. This section states only what a
theorem reaching the pipeline therefore is, and does not restate those
questions.

Each record the generator emits carries these fields, and the
pipeline consumes all of them:

| Field | What it is |
| --- | --- |
| `id` | `T1`, `T2`, … — the handle every later step uses |
| `claim` | the claim itself, in the wording the generator emitted |
| `issues` | the member issue(s) the theorem is tagged to |
| `class` | `mechanical` (grep-shaped) or `semantic` (needs reading behavior) |
| `pointers` | files, regions, or symbols the disprover starts from |

`issues` is a list rather than a single value because a theorem about
a shared helper, or about the single version bump a batch shares,
belongs to every member it affects — that is what makes each of their
verdicts reflect it. A theorem tagged to no member is malformed: it
would produce a finding no verdict line carries, which is exactly how
a defect escapes the overall verdict.

The generation skill (`sdlc:theorem-generation`) owns *what* theorems
to generate. This section owns only the record shape the pipeline
reads.

## Findings must quote, not paraphrase

Every finding that references the content of a file, PR body, commit
message, or code line **must include verbatim quoted evidence** from
the source. Paraphrasing is forbidden — it has produced fabricated
findings where the "offending text" the reviewer claimed to see did
not exist (see #64).

Use this exact format for every finding:

```markdown
**Finding:** <description>
**Evidence:** in `<file-or-location>` at <line/section>:
> <verbatim quote of the offending text>
**Recommendation:** <what to change>
```

Rules:

- The line under `**Evidence:**` that starts with `>` must be a
  byte-for-byte copy of the source text, not a summary, not a
  reconstruction from memory, and not a "this is roughly what it says"
  paraphrase. In this pipeline that quote arrives from the disprover
  that produced it and is copied through unchanged — the pipeline
  never re-derives it.
- For findings about the **absence** of something (e.g. "no test
  coverage for X", "no input validation on Y"), the `**Evidence:**`
  block must (a) name where the thing would normally appear (e.g.
  `tests/foo.py`), AND (b) include a verbatim quote of the surrounding
  code that should have contained it. Both parts are required.
- Findings without a verbatim `**Evidence:**` quote are malformed.

Why this matters: a hallucinated quote is immediately falsifiable
against the file the disprover claims to have read, so the human can
spot-check findings cheaply. A paraphrased finding forces them to
re-do the whole review to verify it, defeating the point of the
pipeline.

## Before claiming file-topology issues

A recurring review failure mode is asserting that file X "lacks"
content Y, or that a "dual-location" / "out-of-sync copies" / "stale
reference" problem exists, **without verifying the topology with a
concrete command**. This is a derivative of the global rule in
`rules/label-uncertainty.md` → "The partial-Read case" — that rule
covers any single-file partial-Read negative claim; this section names
the specific review-context variant where the claim spans two paths
that may or may not be the same file.

Before any finding that asserts a path is a separate copy from
another path, is a regular file rather than a symlink, is out of sync
with another location, or doesn't contain content that exists
somewhere else, at least one of these must have been run:

```bash
git rev-parse --show-toplevel   # is this path inside the repo? where's the root?
readlink <path>                 # symlink target, or non-zero exit if regular file
ls -la <dir>                    # shows symlinks vs regular files in a directory
diff <path-A> <path-B>          # do two paths have different content?
```

A disprover that reports `DISPROVED` on a topology claim without such
a command has not disproved it. That report is malformed, so it is
sent back at step 5 before any verifier is spawned; if the second
report is still unverified, treat the theorem as unsettled rather than
filing the finding. A hedged-but-wrong topology finding
("appears to be a separate copy", "likely out of sync") still lands as
fact to the reader and is the exact failure mode this section exists
to prevent.

## A finding is a disproved theorem whose counterexample survived

That is the entire definition. A finding is never a candidate
observation somebody had while reading; it is a claim that was stated
in advance, broken by a counterexample, and then held after a second
reader tried to reject that counterexample. Nothing else in the review
body gets a severity label.

The non-finding homes are:

- **A surviving theorem** → the **Verified** list, unnumbered and
  unsevered. Never a finding.
- **A theorem whose counterexample the verifier refuted** → the same
  **Verified** list, with the offered counterexample and the rejection
  reason on its line. Never a finding, and never silently dropped
  either: a near-miss a human can audit is the point of publishing it.
- **An intentional, documented design choice nobody disputes** → not a
  finding at all. If the pipeline disputes it, that dispute was a
  theorem and it is a finding graded on its consequence.
- **A question to confirm intent** → a plain question in the review
  body prose, not a severity-labeled finding.
- **An out-of-scope observation** → a "Follow-up suggestion" and, if
  warranted, a recommendation to file a new issue. Not a finding on
  this PR.

Litmus test: if the recommendation is "no action" or "confirm this was
intended", it is not a finding. Filing non-defects as severity-labeled
findings pads the list with noise and forces the human to re-triage
every review — exactly the work this pipeline exists to do.

## Review body

The body is an **argued report**, not a filled-in form: it says how
the review was conducted, argues each standing counterexample in full,
and keeps the near-misses visible instead of discarding them. Post one
body with these sections, in this order:

1. **Verdicts** — one line per member of the set you review against,
   plus one per any other issue a finding names, plus the overall
   line. See "Per-issue verdicts, one overall".
2. **Review method** — the generator tier that ran, how many theorems
   it emitted, and one paragraph stating the method: theorems
   generated against the PR and its issues, one disprover per theorem
   in parallel, one verifier per disproved theorem attacking the
   counterexample, severities transcribed from the surviving
   counterexample's consequence class. Write it so a reader who has
   never seen this pipeline can weigh the rest of the body.
3. **Change counts** — files changed, additions, deletions, from
   step 1.
4. **Disproved theorems** — one entry per standing finding's theorem,
   in theorem-id order: the theorem's claim, the counterexample
   narrative built on the disprover's `**Evidence:**` quote copied
   through verbatim, the consequence reasoning as the verifier
   confirmed or corrected it, and a closing cross-link `→ Finding N`.
   This is where the evidence lives. On any entry for which no usable
   verifier report exists — a verifier malformed twice, whose finding
   stands anyway — give the consequence as the *disprover* proposed it
   and say the verifier's report was malformed, so the entry never
   claims a verifier confirmation that did not happen.
5. **Findings** — numbered, terse, and actionable, ranked by severity,
   each in the `**Finding:** / **Evidence:** / **Recommendation:**`
   format, each tagged with the theorem id it came from and the
   member(s) it belongs to. Alongside — never instead of — the
   Critical / High / Medium / Low grade, a finding may carry a
   free-text character phrase, and each carries a fix-size
   characterization: "mechanical", "one line", "needs a human ruling",
   or the like. The full evidence narrative is section 4; the finding
   points back at it.
6. **Verified** — every theorem that produced no finding, one line
   each: the id, the claim, and what the disprover checked. For a
   theorem whose counterexample was refuted, the line also carries the
   offered counterexample and the verifier's rejection reason, worded
   as what it is — one offered counterexample, rejected, not a proof
   of the claim. Unnumbered, never counted toward severity.
7. **Theorems that could not be settled**, if any — id and claim, no
   severity.
8. **Verdict** — the overall verdict from section 1 restated in prose,
   with a path to approve: what has to change for it to become
   APPROVED, summarizing the fix sizes from section 5. On an overall
   APPROVED, say what the approval rests on instead.

Sections 4, 6, and 7 together are the **full theorem list**: every
theorem the generator emitted appears in exactly one of them. That is
the coverage audit — a reader can see what was checked, what broke,
and what nearly broke, rather than only the survivors and the
findings. Section 5 is not part of that partition: each of its
findings is the actionable face of an entry in section 4.

### Per-issue verdicts, one overall

Every member of the set you review against — as step 2 resolved it —
gets its own verdict line, graded from that member's findings alone:

```markdown
## Verdicts

- #206 — APPROVED
- #196 — NEEDS_CHANGES (1 High)
- #201 — APPROVED
- **Overall — NEEDS_CHANGES**
```

Any *other* issue this review attaches a finding to gets a line too,
even though it is outside the set you review against. That is what
keeps such a finding from vanishing from the overall verdict. These
are the cases step 2 raises one for:

- **A branch member on the *not claimed* list that the body never
  explains** — step 2 grades that absence High, so it gets a line
  reading `- #207 — NEEDS_CHANGES (1 High, not delivered by this
  PR)`. The diff was never reviewed against it, so that one finding is
  all the line carries.
- **A claimed issue outside the branch's set** — the rogue issue gets
  a line reading `- #310 — NEEDS_CHANGES (1 High, closing line outside
  the branch's set)`, carrying that finding alone.

A sanctioned deferral is not one of them: the body names the member
and says why it is not in this PR, step 2 raises no finding, and it
gets no verdict line. Note it as context below the block.

The overall verdict is the **worst** of the verdict lines in the
block, in the order APPROVED < NEEDS_CHANGES < BLOCKED. It is a
derivation, not a separate judgment: one line at NEEDS_CHANGES makes
the whole PR NEEDS_CHANGES, because the PR merges as one unit. The
overall verdict is what `/github-prs:pr-review-submit` receives.

A finding that spans members — a shared helper both depend on, or the
single version bump the batch shares — is graded once and tagged to
every member it affects, so each of their verdicts reflects it. Its
theorem carried those members in its `issues` field.

For a batch of one whose body closes exactly that issue, this
collapses to a single verdict line whose value equals the overall
verdict, which is the single-issue review as it has always been.

### Findings by severity

Severity is a property of the **consequence of merging the PR as-is** —
never of the topic. A performance nit and a security hole are not
automatically the same severity just because both are "non-functional
concerns"; what matters is what actually happens if this ships
unchanged.

#### Consequence classes are transcribed, not graded

For a finding that came from a theorem, you do not read the
consequence statement and decide a severity: an agent that read the
code already assigned a **consequence class**, and you transcribe it.
Which agent's class you take is settled under the table.

| Consequence class | Severity |
| --- | --- |
| `breaks-production` | Critical |
| `behavior-broken-or-criterion-unmet` | High |
| `defect-no-shipped-breakage` | Medium |
| `optional-polish` | Low |

The class comes from the verifier's `STANDS` report. The disprover
proposed one and the verifier confirmed or corrected it; where the two
disagree the verifier's wins, because it is the second reader and it
had the first opinion in hand. The one case where you take the
disprover's proposal is the one step 5 defines: a verifier malformed
twice, whose finding stands anyway. If a `STANDS` report carries no
class at all, that is a malformed report — re-spawn per step 5 rather
than assigning a class yourself. You are not a source of consequence
grades any more than you are a source of theorems.

This is the same derivation-not-judgment principle the verdicts
already follow, moved one link up the chain: the agent that read the
code grades the consequence, and the main session transcribes.

**The acceptance-criterion floor overrides the table.** A standing
finding on a theorem the generator emitted as an acceptance-criterion
claim is **at minimum High**, whatever class the verifier assigned,
regardless of how small the remaining work looks — a disproved
acceptance-criterion theorem IS an unmet acceptance criterion. That
override keys off the theorem's provenance, which the generator's
claim states and the verifier need not know. It only ever raises a
severity; a `breaks-production` class on such a theorem stays
Critical.

#### The findings that carry no class

Step 2's findings — a claimed issue outside the branch's set, and an
unexplained undelivered branch member — come from no theorem, so no
verifier graded them. Grade them by these definitions, which are
the same ones the classes name:

- **Critical**: merging causes data loss, opens a security hole, or
  breaks production.
- **High**: shipped behavior is materially broken, or an acceptance
  criterion of a member issue is unmet.
- **Medium**: a real defect or debt that should be fixed in this PR
  but does not break shipped behavior.
- **Low**: genuinely optional polish. If it must be fixed before
  merge, it is not Low — re-grade it Medium or higher.

A finding whose entire remedy is rewording a comment or docstring is
at most Low — *unless* the comment masks an unmet acceptance criterion
(e.g. a comment asserting a criterion is satisfied when it isn't), in
which case the finding IS the unmet criterion and is graded High per
the floor above, not Low for "just a comment fix."

## Verdict follows from findings

Each verdict line is a mechanical consequence of the findings tagged
to the issue it names — a member of the set, or one of the extra
issues "Per-issue verdicts, one overall" above gives a line to — not a
separate judgment call:

- Any open Critical, High, or Medium finding tagged to that issue →
  `request-changes` (report `NEEDS_CHANGES`, or `BLOCKED` if the fix
  is outside the issue's scope and needs human decision).
- Only Low findings, or no findings at all → `approve`.

The overall verdict is then the worst of those lines, per "Per-issue
verdicts, one overall" above — also mechanical. Every finding must be
tagged to one of those lines; that is what keeps an open Critical,
High, or Medium from ever leaving the overall verdict at APPROVED.

This is a hard invariant, not a guideline. "APPROVED (1 High)" is
malformed by definition — it cannot occur under a correct review. If
you feel the pull to approve despite an open High or Medium, that
feeling means the severity grading is wrong, not that the invariant
should bend: re-grade the finding rather than approving with an open
non-Low finding.

## Report back

Report every verdict line posted — APPROVED, NEEDS_CHANGES, or
BLOCKED, one per member plus any extra line per "Per-issue verdicts,
one overall" — plus the overall verdict, plus severity counts
(Critical, High, Medium, Low) covering findings only. Report the
theorem tally alongside: how many were generated, how many disproved,
how many of those disproved had their counterexample **refuted by
verification**, how many survived, how many went unsettled. Surviving,
refuted, and unsettled theorems are never counted toward severity: a
surviving or refuted theorem lands in the Verified list and an
unsettled one under "Theorems that could not be settled", and none of
them produces a finding.

The refuted count is the one number that says what the verification
stage bought this round, so report it even when it is zero.

Also report which generator tier ran, so an override has something to
disagree with.
