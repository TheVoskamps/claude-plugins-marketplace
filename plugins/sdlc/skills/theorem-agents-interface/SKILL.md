---
name: theorem-agents-interface
description: The interface between the sdlc reviewer and the theorem agents it spawns — what each double-dash brief parameter means, which brief the generator and the assessor each receive, and what each consequence class means. Preloaded into every theorem agent (sdlc:theorem-generator, sdlc:theorem-assessor, the disprover, and the verifier) via its skills frontmatter, and read by name by the sdlc:theorem-based-pr-reviewer agent for what its briefs' parameters mean; not invoked from the user's slash menu.
user-invocable: false
---

# Theorem Agents Interface

This is the one statement of what goes into a theorem agent and what
comes back out. An `## Inputs` section names which of the parameters
below one agent's brief carries and adds only what is specific to
that agent, in that agent's own file: `agents/theorem-generator.md`,
`theorem-assessor`'s, `theorem-disprover`'s and
`counterexample-verifier`'s. The meaning of
a parameter is stated here and nowhere else.

The reviewer reads this file too, rather than only writing against it:
what a parameter of the briefs it writes means — whether `--fetched`
holds, say — is stated here. It reaches this skill by name rather than
by preload.

The reviewer's *own* inputs — the flags `/sdlc:orchestrate` and
`/sdlc:git-review-pr` pass to it — are a different interface, owned by
that agent's Inputs section. Some spell the same as parameters below
(`--pr`, `--issues`, `--branch`) but carry a different contract there:
the reviewer's `--issues` is a claim it reconciles, where a theorem
agent's `--issues` is settled.

The generator's theorem *record* carries the same vocabulary again, on
a third surface: `agents/theorem-generator.md` states what a generator
puts in each record field, and the reviewer's "The theorem contract"
tabulates what it consumes from one. A record is not a brief — the
reviewer transcribes the former into the latter — so neither is a
restatement of this file, and a class renamed or redefined here sweeps
them as well.

## The three generator briefs

A generator receives one of three briefs, and which one decides its
whole workflow:

- The **whole-PR brief** — `--pr`, `--issues`, `--branch`,
  `--round`, `--mode`, and, under `--mode code-and-instruction-markdown`,
  the documentation-paths line when the PR changes a documentation
  file. The generator reads the whole diff and emits the full list.
- The **delta brief** — the whole-PR brief plus `--delta-commits`,
  and a line naming the `print-records` command, `--pr` and `--round`
  filled in, that the generator runs first after its `enter` record.
  The generator reads the carried records out of the PR's state itself
  with it and emits only what the delta implies that they do not
  cover.
- The **issues-only brief** — `--issues` and `--branch` **only**. No
  PR exists yet: `--branch` names the repo's default issue source
  branch rather than a PR head, and the brief carries no `--pr`,
  `--round`, `--delta-commits`, `--mode` and no
  documentation-paths line, because none of those exists: the seed is
  round 0, whose records the first `code-and-instruction-markdown`
  round carries. The
  generator reads the issue bodies and that branch's tree, emits the
  acceptance-criterion theorems and the theorems the issues' design
  and file lists warrant, and points into the issue text or the
  current tree. Its list is a **seed**: the orchestrator settles it,
  and the settled list becomes the round-0 records the PR's first
  review round carries.

## The assessor briefs

`theorem-assessor` receives one of two briefs, each ending in a
`Candidates:` line followed by the theorem records to assess, verbatim
in the generator's record format, and by nothing on an empty list:

- The **seed brief** — `--issues`, `--branch` naming the default issue
  source branch, and `--mode code-and-instruction-markdown`, the seed
  being the code loop's round 0. The candidates are the seed
  generator's list. No `--pr` exists, so the assessor records nothing.
- The **review-round brief** — `--pr`, `--issues`, `--branch`,
  `--base`, `--round` and `--mode`. The candidates are the theorems the
  round's generator emitted, never one minted from an adjustment
  comment and never a `RETIREMENTS` line.

## The brief parameters

- `--pr <host>/<owner>/<repo>#<N>` — the pull request under review, by
  its canonical reference: its repository, host included, then its
  number. Every `github-prs` verb takes it as it stands. Absent on the
  issues-only brief.
- `--branch <name>` — the PR's head branch, or on the issues-only
  brief and the assessor's seed brief the default issue source
  branch. Every theorem agent checks
  it out **detached**, from `origin/<branch>`, in its own worktree.
  Without it, stop and say so rather than reading the branch from
  GitHub yourself. The disprover's and the verifier's own `## Inputs`
  each name what that agent is left with nothing to work against.
- `--base <name>` — the PR's base branch. Only the assessor receives
  it, on the review-round brief: the merge base of `origin/<base>` and
  `origin/<branch>` is the tree before the change.
- `--head-sha <oid>` — optional. The PR's head commit as the reviewer
  read it. When the agent's `origin/<branch>` already points at it,
  there is nothing to fetch.
- `--fetched yes` — optional. The reviewer fetched `origin` in its own
  session immediately before spawning the agent, so the shared ref
  store is already current. The agent's own checkout step decides from
  this and `--head-sha` whether to fetch at all.
- `--theorem T<k>` — the theorem's handle, from the generator's
  record. Reports are filed under it.
- `--claim <text>` — the generator's claim, verbatim from its record:
  the sentence a disprover tries to break, and the one a verifier
  re-reads as written rather than as the disprover restated it.
- `--issues <N…>` — for a generator or the assessor, the whole issue
  set the PR is reviewed against — on the issues-only brief and the
  assessor's seed brief, the batch's resolved issue set; on every other
  brief, the set the pipeline
  already resolved, so the generator neither re-derives it, parses the
  branch name, nor adds or removes a member; for a disprover or a
  verifier, the member issue(s) the theorem is tagged to, which is
  context for the consequence statement and nothing more — neither
  reviews against them.
- `--settle-mode <mechanical|semantic>` — how the generator expects
  the claim to be settled. `mechanical` means a grep, a file listing,
  or a one-command check should do it; `semantic` means reading
  behavior or exercising code. It is a hint about the claim, not a cap on what the
  agent may read: a `mechanical` claim that turns out to need reading
  gets read.
- `--pointers <text>` — the generator's pointers, verbatim: the files,
  regions, or symbols to start from.
- `--delta-commits <oid…>` — the round's change, as the list of this
  PR's **own** commits that have no patch-equivalent commit in the head
  the previous round reviewed. `sdlc:theorem-based-pr-reviewer` →
  "Carry the previous round's theorems forward" computes it and
  bounds it to the PR's own commits, so a rebase that advanced the base
  cannot put the base branch's commits in it. Only a generator
  receives it, and its presence is what makes a brief the delta brief;
  more than one round kind sends that brief, and the reviewer's "Carry
  the previous round's theorems forward" decides which, so read the
  round taxonomy there rather than inferring it from this parameter. A
  clean rebase leaves the list **empty**, and so does an
  adjustment-only round: an empty value is a delta of nothing, not a
  missing parameter.
- `--counterexample <text>` — a disprover's full `DISPROVED` report,
  verbatim, as its result file holds it — `VERDICT`,
  `THEOREM`, `COUNTEREXAMPLE`, `EVIDENCE`, `CONSEQUENCE`, and
  `CONSEQUENCE-CLASS`. Only a verifier receives it.
  It travels unchanged because a paraphrase is precisely what the
  verifier is checking for.
- `--round <n>` — the review round, as the reviewer numbers it.
- `--mode <code-and-instruction-markdown|documentation>` — which file
  classes the round reviews, as the global Claude configuration
  defines them, and so the round's type. Under
  `code-and-instruction-markdown` the round reviews code and
  instruction Markdown, and no claim is about a documentation file.
  Under `documentation` it reviews documentation alone: every claim is
  about a documentation file, and the code and instruction Markdown
  the PR changed are read only for the facts a documentation file
  restates, never as a subject of their own. A child settles its
  theorem under the mode its brief names, and never reports a defect
  in a file outside that mode's classes as a counterexample.

`--pr`, `--round` and `--mode` say nothing about the claim, and
**every** theorem agent receives them, the generator and the assessor
included — on every brief but the issues-only one and the assessor's
seed brief, which have no PR to key a path on, the seed brief carrying
`--mode` alone. Each passes `--pr` and `--round`
straight back — alongside its own stage and its own definition's
name — to
`sdlc-agent-result-persist`, per
`sdlc:agent-result-persist-interface`, when it records that it started
and when it writes its report. Nothing else is passed in: that script
derives the agent id from the worktree the agent is standing in, so a
re-spawned child is distinguishable from the one it replaced without a
handle travelling in a brief.

Two brief lines are not parameters: the assessor's `Candidates:`
block, which "The assessor briefs" describes, and this one. A
generator's or a disprover's
brief can carry `Leave these documentation paths out of every diff you
read:` — on a generator's delta-round brief, `… every diff and delta
commit you read:` — followed by paths. Each is a documentation file
the PR changes; the reviewer lists them because documentation is
outside a `code-and-instruction-markdown` round's review. Comply by
treating those paths' hunks as absent from every diff and delta commit
you read: settle nothing from them,
and name none of them in a claim, a pointer, or a counterexample. The
line is absent when the PR changes no documentation file, under
`--mode documentation`, and on the issues-only brief, and it narrows
what you read, never what you may check out.

## The disprover's outcomes

A disprover's report carries exactly one of four verdicts, each in the
shape `theorem-disprover`'s own "Output" section gives:

- `DISPROVED` — a counterexample breaks the claim;
- `SURVIVED` — the disprover could not break it;
- `UNSETTLED` — settling the claim needs what the disprover cannot run;
- `SUBJECT REMOVED` — the code, text or symbol the claim is about does
  not exist at the head under review.

## The consequence classes

A `DISPROVED` report and a `STANDS` report each carry one of exactly
these tokens as its `CONSEQUENCE-CLASS`, alongside its `CONSEQUENCE`
statement:

- `breaks-production` — merging causes data loss, opens a security
  hole, or breaks production.
- `behavior-broken-or-criterion-unmet` — shipped behavior is
  materially broken, or an acceptance criterion of a member issue is
  unmet.
- `defect-no-shipped-breakage` — a real defect or debt that should be
  fixed in this PR but does not break shipped behavior.
- `optional-polish` — genuinely optional. If it must be fixed before
  merge, it is not this one.

The class grades the **consequence of merging as-is**, never the
topic. A generator assigns no consequence class at all —
`--settle-mode` above is a different vocabulary, about how a claim
gets settled — and
only `theorem-disprover` and `counterexample-verifier` do; which of
the two the reviewer takes when they disagree is stated in each of
those agents' own "The consequence classes" section, from where that
agent stands in the chain. What severity each class becomes is the
reviewer's business, not the agents' — an agent grades the
consequence, not the severity, and never argues for a severity in its
report.
