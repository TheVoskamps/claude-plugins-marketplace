---
name: theorem-agents-interface
description: The interface between the sdlc review pipeline and the theorem agents — what each double-dash brief parameter means, and what each consequence class means. Preloaded into every theorem agent (the generator variants, the disprover, and the verifier) via its skills frontmatter, and read by name by sdlc:pr-review-pipeline for the class glosses; not invoked from the user's slash menu.
user-invocable: false
---

# Theorem Agents Interface

This is the one statement of what goes into a theorem agent and what
comes back out. The `sdlc:pr-review-pipeline` skill writes the briefs;
the generator variants, `theorem-disprover`, and
`counterexample-verifier` receive them and answer. An `## Inputs`
section names which of the parameters below one agent's brief carries
and adds only what is specific to that agent — `theorem-disprover`'s
and `counterexample-verifier`'s in their own agent files, the
generator's in `sdlc:theorem-generation`, since the generator
skeletons hold no instructions of their own. The meaning of a
parameter is stated here and nowhere else.

The pipeline reads this file too, rather than only writing against it:
its step 2 findings come from no theorem, so it grades them by the
class glosses below and then transcribes the class into a severity by
its own table. That is the one reader that is not an agent, and it
reaches this skill by name in the main session rather than by
preload.

The pipeline's *own* inputs — the flags `/sdlc:orchestrate` and
`/sdlc:git-review-pr` pass to it — are a different interface, owned by
that skill's Inputs section. Some spell the same as parameters below
(`--pr`, `--issues`, `--branch`) but carry a different contract there:
the pipeline's `--issues` is a claim it reconciles, where a theorem
agent's `--issues` is settled.

The generator's theorem *record* carries the same vocabulary again, on
a third surface: `sdlc:theorem-generation` states what a generator
puts in each record field, and the pipeline's "The theorem contract"
tabulates what it consumes from one. A record is not a brief — the
pipeline transcribes the former into the latter — so neither is a
restatement of this file, and a class renamed or redefined here sweeps
them as well.

## The brief parameters

- `--pr <N>` — the pull request under review.
- `--branch <name>` — the PR's head branch. Every theorem agent checks
  it out **detached**, from `origin/<branch>`, in its own worktree.
  Without it, stop and say so rather than reading the branch from
  GitHub yourself. The disprover's and the verifier's own `## Inputs`
  each name what that agent is left with nothing to work against.
- `--head-sha <oid>` — optional. The PR's head commit as the pipeline
  read it. When the agent's `origin/<branch>` already points at it,
  there is nothing to fetch.
- `--fetched yes` — optional. The pipeline fetched `origin` in its own
  session immediately before spawning the agent, so the shared ref
  store is already current. The agent's own step 1 decides from this
  and `--head-sha` whether to fetch at all.
- `--theorem T<k>` — the theorem's handle, from the generator's
  record. Reports are filed under it.
- `--claim <text>` — the generator's claim, verbatim from its record:
  the sentence a disprover tries to break, and the one a verifier
  re-reads as written rather than as the disprover restated it.
- `--issues <N…>` — for a generator, the whole issue set the PR is
  reviewed against; for a disprover or a verifier, the member issue(s)
  the theorem is tagged to, which is context for the consequence
  statement and nothing more — neither reviews against them.
- `--class <mechanical|semantic>` — how the generator expects the
  claim to be settled. `mechanical` means a grep, a file listing, or a
  one-command check should do it; `semantic` means reading behavior or
  exercising code. It is a hint about the claim, not a cap on what the
  agent may read: a `mechanical` claim that turns out to need reading
  gets read.
- `--pointers <text>` — the generator's pointers, verbatim: the files,
  regions, or symbols to start from.
- `--counterexample <text>` — a disprover's full `DISPROVED` report,
  verbatim, every line as the disprover wrote it — `VERDICT`,
  `THEOREM`, `COUNTEREXAMPLE`, `EVIDENCE`, `CONSEQUENCE`, and `CLASS`.
  It travels unchanged because a paraphrase is precisely what the
  verifier is checking for.

## The consequence classes

A `DISPROVED` report and a `STANDS` report each carry one of exactly
these tokens as its `CLASS`, alongside its `CONSEQUENCE` statement:

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
topic. A generator assigns no consequence class at all — the `--class`
above is a different vocabulary, about how a claim gets settled — and
only `theorem-disprover` and `counterexample-verifier` do; which of
the two the pipeline takes when they disagree is stated in each of
those agents' own "The consequence classes" section, from where that
agent stands in the chain. What severity each class becomes is the
pipeline's business, not the agents' — an agent grades the
consequence, not the severity, and never argues for a severity in its
report.
