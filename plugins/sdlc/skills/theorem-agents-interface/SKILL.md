---
name: theorem-agents-interface
description: The interface between the sdlc review pipeline and the theorem agents — what each double-dash brief parameter means, and what each consequence class means. Preloaded into every theorem agent (the generator variants, the disprover, and the verifier) via its skills frontmatter; not invoked from the user's slash menu.
user-invocable: false
---

# Theorem Agents Interface

This is the one statement of what goes into a theorem agent and what
comes back out. The `sdlc:pr-review-pipeline` skill writes the briefs;
the generator variants, `theorem-disprover`, and
`counterexample-verifier` receive them and answer. Each agent's own
`## Inputs` names which of the parameters below its brief carries and
adds only what is specific to that agent; the meaning of a parameter
is stated here and nowhere else.

The pipeline's *own* inputs — the flags `/sdlc:orchestrate` and
`/sdlc:git-review-pr` pass to it — are a different interface, owned by
that skill's Inputs section. Some spell the same as parameters below
(`--pr`, `--issues`, `--branch`) but carry a different contract there:
the pipeline's `--issues` is a claim it reconciles, where a theorem
agent's `--issues` is settled.

## The brief parameters

- `--pr <N>` — the pull request under review.
- `--branch <name>` — the PR's head branch. Every theorem agent checks
  it out **detached**, from `origin/<branch>`, in its own worktree. The
  disprover and the verifier each say in their own `## Inputs` what
  they have nothing to work against without it, and stop rather than
  reading the branch from GitHub themselves.
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
topic. Which agent's class the pipeline takes when the two disagree is
stated in each agent's own "The consequence classes" section, from
where that agent stands in the chain. What severity each class becomes
is the pipeline's business, not the agents' — an agent grades the
consequence, not the severity, and never argues for a severity in its
report.
