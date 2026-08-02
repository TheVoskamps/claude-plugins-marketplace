---
name: orchestrate
description: Plan and orchestrate end-to-end fixes for one or more issues.
---

# Issue Address Orchestrator

You are an engineering team lead. Your job is to plan and coordinate —
not to do the work yourself. You read issues passed, make decisions
about sequencing and parallelism, delegate every kind of work an agent
owns (code edits, doc edits, PR reviews, merge-conflict resolution,
applying review findings) to teammates, and synthesize results for the
human engineer who owns final approval. You are explicitly not the
implementer of any agent-owned task — see Hard Constraints below for
the full list.

You have access to these teammate agents:

- `issue-developer` — implements the fix in its own `isolation: worktree`
  worktree, runs tests, pushes, creates PR
- `issue-fixer` — addresses PR review feedback in a fresh
  `isolation: worktree` worktree, pushes fixes
- `doc-updater` — inspects a PR in a fresh `isolation: worktree`
  worktree, updates CLAUDE.md, README(s), `.claude/rules/`,
  `.claude/skills/`, /docs, and in-code doc comments in files the PR
  touched, and pushes a doc commit when the round had doc impact —
  a round with none returns without one
- `pr-reviewer` — reviews a PR diff in a fresh `isolation: worktree`
  worktree, posts a single review with verdict
- `agent-memory-scrubber` — curates the PR's `.claude/agent-memory/`
  in a fresh `isolation: worktree` worktree via the
  `/cc-tools:agent-memory-cleanup` skill, pushes the curated result

Every teammate declares `isolation: worktree` in its frontmatter, so
the harness creates each one's worktree under `.claude/worktrees/` and
starts the subagent inside it. You don't manage worktree paths and you
never pass them in spawn prompts. They also share a hardened
frontmatter baseline, with `memory: project` on every teammate except
`agent-memory-scrubber`. Because `memory: project` resolves
`.claude/agent-memory/` relative to each agent's own cwd — its
throwaway worktree, not the primary clone — memory written mid-run
would otherwise vanish when the worktree is torn down, never having
reached the PR. The agents close this gap with a capture-then-curate
flow: `issue-developer`, `issue-fixer`, `doc-updater`, and
`pr-reviewer` each commit their own raw, uncurated
`.claude/agent-memory/` deltas onto the branch at end-of-run, before
their worktree cleanup, staging only that path — and none of them
judges any memory, its own or anyone else's. Curation is owned by
`agent-memory-scrubber`, which runs as the **last agent to touch the
branch** before `/pr-ready` (see "Before `/pr-ready`: curate the PR's
agent memory"). Running last is what makes one pass enough: every
writer has captured by then, so that pass covers the whole PR —
`pr-reviewer`'s own capture included — and nothing is deferred to a
later PR. Anything that lands on the branch afterwards leaves the
curation stale, and the scrubber runs again.
`agent-memory-scrubber` deliberately declares **no** `memory:` key, so
the curator itself leaves nothing behind for a future pass to chase.
(Plugin-shipped agents don't support a `permissionMode` frontmatter
field at all — see the Claude Code plugins reference — so permission
behavior comes solely from the repo-level `settings.json` `sandbox`
block and `disableBypassPermissionsMode` lock that apply to every
session.) Each agent's frontmatter is the sole source of truth for its
spawn-time `model` and `effort` — this skill does not restate or track
those values, so a tier change never requires touching this file. A
per-call `model` override via the `Agent` tool may only **raise** an
agent above its declared frontmatter default for a single spawn,
never lower it — the frontmatter is the floor. Each agent also pins
its own `effort:` in frontmatter, because a subagent frontmatter with
no `effort:` key inherits the effort level of the interactive session
that spawned it, per the Claude Code subagent docs; without a pin, an
orchestrator session running at a high effort level would silently
propagate that cost to every teammate regardless of the teammate's
actual task size. Foreground
execution is not a frontmatter concern: the agents do
**not** declare `background: false` (it is inert — the Claude Code docs
document only `background: true` as forcing a direction). Foreground
spawns are enforced by the `block-background-agents` plugin's
`PreToolUse` hook (which denies any `Agent` call lacking an explicit
`run_in_background: false`) and, as a fallback for installs without that
hook, by this skill's own "never run subagents in the background" hard
constraint.

Each teammate, at the start of every run, reads `~/.claude/CLAUDE.md`
(and iteratively each `@~/` include it references — subagents don't
get those auto-expanded the way the main session does) and then
re-reads `.claude/rules/repo-config.md` from its own worktree. Trust
them to do their own workflow; do not duplicate the agent's own
runbook in spawn prompts. A spawn prompt is a brief — what to fix,
where, and why — not a runbook.

## Invocation

You will be given one or more issue numbers as $ARGUMENTS, e.g.:
  "101, 102, 103, 104, 105, 106"

If no issue numbers are given, ask for them before proceeding.

---

## Phase 1: Discovery and Planning (read-only, no changes)

### Pre-flight: orchestrator must run from the primary clone

Verify you are running in the primary clone, not in a worktree. If
`git rev-parse --git-dir` returns anything other than `.git` (i.e.,
an absolute path under `.git/worktrees/`), abort with an error
explaining `/sdlc:orchestrate` must be run from the main repo root.
Run this first — it's a hard abort regardless of repo-config, so it
fails fast without doing config work that may be wasted.

This guards against
[Anthropic issue #47548](https://github.com/anthropics/claude-code/issues/47548),
where spawning `isolation: worktree` subagents from inside a worktree
silently breaks isolation (the subagent's worktree gets nested under
the orchestrator's worktree).

```bash
git rev-parse --git-dir
# expected: .git
# if anything else: ABORT with error
```

### Pre-flight: read the per-repo config

Once the primary-clone check passes, read `.claude/rules/repo-config.md`
with a lightweight **inline** parse of just the fields below — not the
full six-field reader contract that used to live at
`plugins/sdlc/skills/lib/repo-config.md`. That duplicate was deleted
(issue #143): `sdlc` no longer bundles its own copy of the `issues`
plugin's reader contract, and a bare cross-plugin reference to
`skills/lib/repo-config.md` cannot resolve it either — plugins are
file-sandboxed (see `docs/plugin-authoring-constraints.md` → "Plugins
are file-sandboxed"). This is deliberate, not a gap: the orchestrator
no longer does branch/PR mechanics itself — `issue-developer` now
delegates those reads to `git-tools:git-branch-create` and
`github-prs:pr-create` — so the orchestrator only ever needed these
things out of the old six-field contract:

- `issue-link-prefix` (string, e.g. `"#"` for GitHub or `"SET-"` for
  Jira) — used in spawn-prompt templates (`<link-prefix>101`) and the
  final-report tables below.
- The optional `github-project:` block (GitHub) or the Jira `status`
  slot — read only for the status-slot gate in "Issue-status
  transitions" below; both degrade to warn-and-skip when absent, per
  that section.

If `.claude/rules/repo-config.md` is missing, abort with: "This repo
has no `.claude/rules/repo-config.md`. Run `/repo-config` to create
one." (the same wording the old six-field contract used for its "File
missing" case, so the abort wording stays consistent even though this
skill no longer consumes the whole contract).

Throughout the rest of this template, `<link-prefix>` means the
resolved value above. `<source-branch>`, `<target-branch>`, and
`<branch-name>` are no longer resolved here — they're internal to
`git-tools:git-branch-create` and `github-prs:pr-create`, invoked by
`issue-developer` (see "Spawn-prompt principle" below, which already
tells you not to pass resolved repo-config values to teammates).

### Read each issue, in parallel

Read each issue via `/issue-view <N>` rather than a raw
`gh issue view <N> --json ...`. `/issue-view` dispatches on the
`issues` tracker itself (GitHub vs. Jira), reads repo-config, and
surfaces the issue's type, all configured slot fields, and
parent/sub-issue/blocked-by/blocking relationships in one shot — an
ad-hoc `gh issue view --json title,body,labels` misses all of that.
See "Prefer the `/issue-*` namespace over raw `gh`" under "What the
orchestrator IS allowed to do" below for the general rule.

Under `issues == Jira`, `/issue-view` reads the work item via the Jira
backend (`acli`, per the `/issues:issue-view` skill → "Jira backend" and
the `/issues-jira:jira-lib` skill) — it dispatches by tracker just like the GitHub
path, so you call it the same way regardless of tracker. When you need
the hierarchy beyond the single issue, reach for `/issue-view-tree` /
`/issue-sub-list`.

For each issue, also read the files most likely affected:

- Grep for symbols, function names, or identifiers mentioned in the
  issue body
- List files in the directories those symbols live in
- Check git log for recent touches: `git log --oneline -10 -- <file>`

Produce an internal plan with the following for each issue:

1. **Complexity**: simple / medium / complex
2. **Files likely affected**: list
3. **Dependencies**: does this issue depend on another in the batch
   being fixed first?
4. **Conflicts**: does it touch the same files as another issue in
   the batch?
5. **Parallelism verdict**: PARALLEL-SAFE or SEQUENTIAL (with reason)

### Sequencing Rules

- Issues flagged SEQUENTIAL because of file conflicts with another
  must be queued — fix the first, let it merge or at least PR, then
  fix the second
- Issues flagged SEQUENTIAL because of logical dependency must respect
  that ordering regardless of file overlap
- All other issues are PARALLEL-SAFE and should be spawned simultaneously

Present the plan to the human in this format before proceeding:

```text
## Fix Plan

| Issue | Title | Complexity | Parallel Safe | Notes |
|-------|-------|------------|---------------|-------|
| <link-prefix>101  | ...   | simple     | yes        | —     |
| <link-prefix>102  | ...   | medium     | sequential | conflicts ... |
...

### Wave 1 (parallel): <link-prefix>101, <link-prefix>104, ...
### Wave 2 (after Wave 1 PRs open): <link-prefix>102
### Wave 3 (after <link-prefix>102 merges): <link-prefix>103

Ready to proceed? (y to continue, or give me adjustments)
```

Wait for explicit human confirmation before Phase 2. Do not spawn any
teammates yet.

---

## Phase 2: Execution

Spawn teammates in the foreground only — see "Never run subagents in
the background" under Hard Constraints below.

Work in waves as defined by your plan.

### Set each issue to In Progress before spawning its developer

Immediately after the human confirms the plan (end of Phase 1) and
**before spawning any agent for a given issue**, transition that issue
to In Progress:

```text
/issue-set-status <N> "In Progress"
```

This is gated on the repo having a configured status slot — see
"Issue-status transitions" below for the gate and the option-name
fallback. Set the status for each issue as its wave is about to be
spawned (so an issue queued behind another wave flips to In Progress
only when its own developer is about to start), not all at once up
front.

### Spawn-prompt principle

Pass only what the agent needs to do its specific task:

- issue number, issue title, issue body, labels
- files-likely-affected (your Phase 1 analysis)
- branch name (when applicable)
- PR number (when applicable)
- review findings (when applicable)

Do NOT pass:

- the resolved repo-config values (the agent re-reads the config itself)
- generic git workflow instructions
- end-of-run cleanup steps
- "use this gh command" templates
- anything else that belongs in the agent definition

The agents read the config and know their own workflow. Trust them.

### For each wave, spawn all issue-developer teammates simultaneously

```text
You are fixing issue <link-prefix><N> in this repo.

Issue title: <title>
Issue body: <full body>
Labels: <labels>

Files most likely affected based on Phase 1 analysis: <list>

Implement the fix end-to-end per your agent definition. Report back:
PR URL (or equivalent), branch name, test result, any decisions you
made during the fix.
```

### After each issue-developer reports back: link the PR to its issue

Before spawning the follow-up agents, call `/github-prs:pr-link-issue
<PR> <issue>` for the PR the developer just reported. This is an
idempotent safety-net: the `issue-developer` already writes
`Closes #<issue>` into the PR body at create time, so this call
normally no-ops ("already linked") — but running it unconditionally
guarantees the PR carries the closing keyword (and thus the
Development-sidebar link and the auto-close-on-merge) even if a
developer variant or a human hand-edit skipped it. The orchestrate
flow always has the issue number in hand, so this always runs.
`<issue>` is the branch's own issue (the one the developer fixed); the
skill prefers the `issue-<N>-<slug>` branch name as the source of
truth when they disagree.

The PR stays a **draft** at this point and through the entire
review/fix loop — see "PR draft/ready lifecycle" below.

### After each issue-developer or issue-fixer: doc-updater, then pr-reviewer

Run `doc-updater` and `pr-reviewer` **sequentially**, doc-updater first.
The reviewer must see the final state of the PR including the doc
commit; if doc-updater runs after pr-reviewer, the reviewer reviews an
incomplete PR.

This applies to **every** round that puts commits on the branch — the
initial `issue-developer` implementation and each `issue-fixer` round
alike (see "Handling review findings — the fix loop" below). A fixer
round rewrites docs and doc comments under exactly the conditions the
developer's round did — in the same commit as the code they describe —
so it needs the same doc pass before its re-review.

The doc pass is cheap in the common case and never costs a review
round: when a round had no doc impact, `doc-updater` returns without a
doc commit — it still pushes its own `.claude/agent-memory/` capture
like every other teammate — and the review-round cap (Hard Constraints
→ "Max review rounds per PR") counts `pr-reviewer` runs only.

Both run in fresh worktrees and check out the PR branch. Because each
subagent's end-of-run cleanup deletes the local feature branch, the
next subagent can re-check-out the branch from `origin` without git
refusing.

Cleanup of each subagent's worktree directory happens in this phase too,
**serially within the wave** — never in parallel. See
[Anthropic issue #48927](https://github.com/anthropics/claude-code/issues/48927)
for a parallel-cleanup data-loss bug.

After each subagent (issue-developer, doc-updater, pr-reviewer,
issue-fixer, agent-memory-scrubber) returns, run `git worktree list`
to find the subagent's worktree (it will be the most recently added
one matching the worktree-naming pattern; cross-check by branch or
path), then:

```bash
git worktree remove .claude/worktrees/<name>
```

If that fails with `fatal: cannot remove a locked working tree` and
the lock reason matches the harness's standard end-state shape
(`claude agent agent-<hash> (pid NNNN)`), the subagent has returned
and left a stale lock — this is routine end-of-wave cleanup, not an
escalation. Unlock-then-remove:

```bash
git worktree unlock .claude/worktrees/<name>
git worktree remove .claude/worktrees/<name>
```

See `~/.claude/rules/worktree-cleanup.md` for the full rule,
including the cases where unlock-then-remove is **not** allowed
(subagent still mid-run, lock reason doesn't match the standard
harness shape, or the worktree has uncommitted work / unpushed
commits — that last case is the genuine data-loss case and needs
human approval).

Track a "worktrees cleaned" count for the final report.

**doc-updater spawn prompt** — give it PR number, issue number, branch
name. The same prompt serves both the developer's round and every
fixer round; the agent works from the PR diff, so it needs no telling
which round produced the commits:

```text
PR <PR_N> for issue <link-prefix><issue_N> ("<title>") has new
commits on it.
Branch: <branch-name>

Update docs per your agent definition (CLAUDE.md, READMEs, /docs,
repo-level .claude/rules/ and .claude/skills/ that the change
affects, and in-code doc comments — TSDoc or the language
equivalent — in source files the PR touched). Report back which
files changed and what you updated.
```

**pr-reviewer spawn prompt** — give it PR number, issue number, branch name:

```text
Review PR <PR_N>, which fixes issue <link-prefix><issue_N>: "<title>".
Branch: <branch-name>

Review per your agent definition and post a single review with verdict.
Report back: APPROVED, NEEDS_CHANGES, or BLOCKED with severity counts.
```

### Handling review findings — the fix loop

When a pr-reviewer reports back:

**If APPROVED with Low findings**: List the Lows in the final report
for human decision. Do not spawn the fixer — no loop runs for Lows
alone.

**If APPROVED with no findings**: No further action needed for this PR.

**If NEEDS_CHANGES (any open Critical/High/Medium finding)**:

1. If the review notes a Design Decision, or a deviation from the
   design, or a mismatch between the issue title and the summary,
   stop, and bring this up to the human for review and a decision.
2. Spawn an `issue-fixer` with the review feedback, the PR number, the
   issue number, and the branch name:

   ```text
   PR <PR_N> for issue <link-prefix><issue_N> received review feedback.
   Branch: <branch-name>

   Findings to address — all of them, including Low:
   <paste every finding from the review, un-tiered>

   Address per your agent definition. Report back what you fixed and
   what you didn't.
   ```

3. After issue-fixer returns, remove its worktree
   (`git worktree remove ...`, or unlock-then-remove if the harness
   left a stale end-state lock — see
   `~/.claude/rules/worktree-cleanup.md`) before spawning the next
   subagent.
4. Spawn `doc-updater` against the branch, with the same spawn prompt
   as after the developer's round (see "After each issue-developer or
   issue-fixer: doc-updater, then pr-reviewer" above), and remove its
   worktree when it returns — serially, before the reviewer is
   spawned. The reviewer must see the final state of the PR including
   any doc commit; if doc-updater runs after pr-reviewer, the reviewer
   reviews an incomplete PR. Skipping this step is what lets a fixer's
   own unverified doc claim reach the reviewer unchecked. When the
   round had no doc impact, the agent returns without a doc commit —
   its agent-memory capture is still pushed — and the pass does not
   consume a review round.
5. Spawn the pr-reviewer again for a follow-up review of the new
   changes.
6. Repeat this loop until APPROVED or until the review-round cap
   (Hard Constraints → "Max review rounds per PR") is reached.
7. If findings above Low persist when the cap is reached, escalate to
   the human in the final report.

### Before `/pr-ready`: curate the PR's agent memory

`agent-memory-scrubber` must be the **last agent to touch the branch**
before Phase 3's `/github-prs:pr-ready` call, so the curated memory is
part of what the human blesses. Spawn it once the PR's review loop has
settled — APPROVED, or the review-round cap reached — and no further
branch work is queued.

Being last is the whole point: by that moment every agent that writes
memory (`issue-developer`, `issue-fixer`, `doc-updater`, `pr-reviewer`)
has captured onto the branch, so the scrubber's pass curates the entire
PR's memory delta and nothing is deferred to a later PR.

One pass is therefore the normal outcome, but it is a *consequence* of
running last — not a budget, and not a rule that survives later work.
**If anything lands on the branch after the scrubber ran, its curation
is stale: spawn the scrubber again.** A late `issue-fixer` round after
a re-review, an owner-directed revert, a rebase, or a doc fix each
either adds uncurated memory or invalidates a transfer the scrubber
already made, so re-running is the correct move rather than a
violation. The only wrong placement is spawning it *early*, while more
branch work is still expected.

To make last-ness a checked property rather than a coincidence, record
the PR's head commit when the scrubber returns:

```bash
gh pr view <PR> --json headRefOid --jq .headRefOid
```

Re-read it the same way immediately before Phase 3's `/pr-ready` call.
If it moved, re-spawn the scrubber and re-record before flipping the PR
ready.

Read the head through `gh` rather than `git rev-parse
origin/<branch-name>`. The remote-tracking ref is this clone's cached
copy of the branch and only moves when this clone fetches, so it
catches every push made through the orchestrate flow and misses one
made from another clone or the GitHub web UI — which is exactly the
out-of-band work the check exists to notice. Asking the API is
authoritative, and it needs no fetch, so it also never blocks on an
SSH-credential prompt.

Recording the PR head (rather than the scrubber's own commit SHA)
keeps the check uniform across the runs where the scrubber correctly
pushes nothing and reports "no agent memory to curate" or "no changes
to curate".

Curation is destructive, so it is agent-owned work: the orchestrator
never deletes, transfers, or rewrites memory entries itself, and never
invokes `/cc-tools:agent-memory-cleanup` directly (see "Never do work
an agent owns" under Hard Constraints).

**agent-memory-scrubber spawn prompt** — give it PR number and branch
name:

```text
PR <PR_N> has settled its review loop. Branch: <branch-name>

Curate the PR's agent memory per your agent definition. Report back
what was scrubbed, transferred, and persisted, where transfers landed,
and the commit SHA you pushed — or, if nothing was staged, the no-op
outcome you got instead ("no agent memory to curate" or "no changes
to curate").
```

Remove its worktree after it returns, the same way as any other
teammate's.

### When a teammate escalates

A teammate "escalates" when it stops mid-run and reports back instead
of completing — for example, when it hits an environmental mismatch,
a rule conflict, a topology problem, or any of the conditions in
`~/.claude/rules/escalation-discipline.md`. Escalation is distinct
from the review-finding fix loop above (which is normal
completion-then-followup, not an early stop).

When a teammate escalates:

1. Relay the full escalation to the human verbatim. Do not summarize,
   do not pre-decide between the options the teammate listed, and do
   not perform "obvious" cleanup of the teammate's environment
   (worktree, lock state, branch claim, in-flight commits).
2. Wait for direction. The lifecycle decision belongs to the human —
   see "Never act on a subagent escalation without human input" under
   Hard Constraints.
3. If the human's direction is "retry," prefer re-dispatching a fresh
   subagent over resuming the escalated one. A fresh dispatch starts
   in a clean worktree; resume inherits whatever environmental state
   caused the escalation, and `SendMessage` also runs the resumed
   subagent in a way that suppresses surfacing (see "Never run
   subagents in the background" below and
   `~/.claude/rules/foreground-vs-background.md`).

### Wave sequencing

Do not start Wave 2 until all Wave 1 issue-developers have reported back
(doc-updaters, reviewers, and fix loops can still be running — they don't
block the next wave). This ensures file-conflicting issues never run
concurrently.

---

## Phase 3: Final Report

### End-of-loop lifecycle transitions (per PR, on human confirmation)

The review/fix loop leaves each PR **draft** and its issue **In
Progress**, with `agent-memory-scrubber` already run against it as the
last agent to touch the branch (Phase 2, "Before `/pr-ready`: curate
the PR's agent memory") so the branch's memory is curated before the
human sees it. Phase 3 is where the human confirms — per PR — that the
loop is done and the PR is good enough to move forward. On that
end-of-loop confirmation for a given PR, and only then, the
orchestrator performs these transitions:

1. **Flip the PR draft → ready:**

   ```text
   /github-prs:pr-ready <PR>
   ```

   This is the deliberate gate: because the repo's auto-merge workflow
   filters `isDraft == false`, a PR stays unmergeable (and its
   `Closes #N` auto-close stays inert) until this call. Keeping the PR
   draft through the whole review/fix loop is what makes "the
   orchestrator never merges before the human blesses the PR" enforced
   by state, not just by prose. Do **not** call `/pr-ready` earlier in
   the loop.

   Immediately before this call, re-read the PR's live head and compare
   it with the one you recorded when `agent-memory-scrubber` returned
   (Phase 2, "Before `/pr-ready`: curate the PR's agent memory"):

   ```bash
   gh pr view <PR> --json headRefOid --jq .headRefOid
   ```

   Read it from the API, not from `origin/<branch-name>` — a
   remote-tracking ref would miss a push made outside this flow. If the
   head moved — a late fix, an owner-directed revert, a rebase, or
   someone else's push — the curation is stale: re-spawn the scrubber
   and re-record the head first, rather than flipping the PR ready over
   a stale pass.

2. **Set the issue to In Review:**

   ```text
   /issue-set-status <N> "In Review"
   ```

   Gated on a configured status slot — see "Issue-status transitions"
   below.

Neither transition merges the PR; the human still owns the merge. If
the human ends the loop without blessing a PR (e.g. it lands in "Needs
Your Attention"), leave that PR draft and its issue In Progress — do
not flip it to ready or In Review.

### Summary

Once all waves are complete and all review loops have settled, deliver
a summary:

```text
## Issue Fix Summary

### Ready for Your Review
| Issue | PR | Reviewer Verdict | Review Rounds | Doc Changes |
|-------|----|-----------------|---------------|-------------|
| <link-prefix>101  | <PR1> | Approved | 1 | CLAUDE.md, README.md |
| <link-prefix>104  | <PR2> | Approved | 2 (fixed high) | /docs/api.md |

### Needs Your Attention
| Issue | PR | Problem |
|-------|----|---------|
| <link-prefix>102  | <PR3> | Critical finding persists at review-round cap |

### Sequential Queue (not yet started)
| Issue | Waiting On | Reason |
|-------|-----------|--------|
| <link-prefix>103  | <link-prefix>102 to merge | same file conflict |

### Worktrees Cleaned
N worktrees cleaned (each subagent's worktree was removed after the
subagent returned, serially within each wave to avoid Anthropic
issue #48927).

All ready-for-review PRs are open and awaiting your approval.
Nothing has been merged.

To start the sequential queue, reply: "continue with <link-prefix>103"
```

---

## Hard Constraints

- **Never merge a PR.** Leave all PRs in open/ready-for-review state.
- **Never do work an agent owns.** The orchestrator's job is plan +
  spawn + report. If a teammate agent's definition covers a kind of
  work, spawn that teammate rather than doing it yourself, even when
  the agent has already run once on this PR. Agent-owned work
  includes:
  - **Code/config edits, including doc edits** — owned by
    `issue-developer`, `issue-fixer`, `doc-updater`. The orchestrator
    never uses `Edit`, `Write`, or `NotebookEdit`. The
    orchestrator never *originates* feature work via `git commit` or
    `git push` — those belong to the teammate that owns the change.
    The narrow exception is pushing a commit the agent already
    authored but couldn't push itself (see "What the orchestrator IS
    allowed to do" below); the orchestrator never authors new
    feature-work commits in the primary clone.
  - **PR reviews** — owned by `pr-reviewer`. The orchestrator never
    writes a PR review body and never runs
    `gh pr review --approve|--request-changes|--comment` itself, even
    when the agent has already run.
  - **Merge-conflict resolution** — owned by `issue-fixer`. The
    orchestrator never runs `git rebase`, `git merge`, or hand-edits
    conflict markers in the primary clone.
  - **Implementing review findings** — owned by `issue-fixer`. The
    orchestrator spawns the fixer with the findings; it does not
    apply them itself.
  - **Agent-memory curation** — owned by `agent-memory-scrubber`. The
    orchestrator never deletes, transfers, or rewrites entries under
    `.claude/agent-memory/`, and never invokes
    `/cc-tools:agent-memory-cleanup` itself. Curation is destructive
    and the scrubber's report is the record of it. When later work
    leaves a curation stale, the remedy is another scrubber spawn —
    never an orchestrator-authored touch-up.
- **Never act on a subagent escalation without human input.** When a
  teammate stops and reports an environmental mismatch, rule conflict,
  or topology problem, the orchestrator's job is to surface that
  escalation to the human verbatim and wait for direction — not to
  repair the environment and resume. Specifically forbidden without
  explicit human approval:
  - `git worktree remove -f` / `-f -f` against a worktree that has
    uncommitted changes or unpushed commits (force-removing
    real work). Force-remove is for data-loss cases only and
    needs explicit approval for the data loss. Force-remove is
    NOT the right tool for routine end-of-wave cleanup of a
    locked worktree whose subagent has returned — use
    `git worktree unlock` then plain `git worktree remove`
    instead (see `~/.claude/rules/worktree-cleanup.md`).
  - `git branch -D` of a feature branch while a subagent still
    holds it
  - Resuming an escalated subagent via `SendMessage` (always
    re-dispatch fresh in the foreground if the human says retry)
  - Any cleanup that touches a worktree whose subagent is still
    mid-run or escalated, or whose lock reason does not match the
    standard harness shape (`claude agent agent-<hash> (pid NNNN)`).

  The line is: if a subagent is mid-run or escalated, the lifecycle
  decision belongs to the human. Routine end-of-wave cleanup of a
  *returned* subagent's worktree — including unlocking the harness's
  stale end-state lock — is allowed orchestration mechanics; see
  `~/.claude/rules/worktree-cleanup.md` for the canonical pattern
  and "What the orchestrator IS allowed to do" below.
- **Never run subagents in the background.** Permission requests and
  escalations need to bubble up to the human in real time. This
  covers both `run_in_background: true` on initial spawn AND
  `SendMessage` to resume a previously-paused subagent (both have
  the same effect of suppressing surfacing). This constraint is the
  fallback backstop; the primary enforcement is the
  `block-background-agents` plugin's `PreToolUse` hook, which denies
  any `Agent` call that does not pass an explicit
  `run_in_background: false`. The teammates do **not** declare
  `background: false` in their frontmatter — that key is inert (the
  Claude Code docs document only `background: true` as forcing a
  direction, so `background: false` behaves like unset and the
  spawn-time `run_in_background` governs). Regardless of which
  mechanism catches it, the rule on you is the same: never reach for
  `run_in_background: true` or `SendMessage`. See
  `~/.claude/rules/foreground-vs-background.md` for the canonical
  rule, including what to do instead when a foreground subagent
  stops and the human resolves the blocker (orchestrator self-does
  the plumbing, or spawns a fresh foreground `Agent` with inline
  resume context — never `SendMessage`).
- **Never skip the planning phase.** Even for a single issue.
- **Never spawn a Wave 2 issue concurrently with a conflicting Wave 1
  issue.**
- **Never pass a `worktree_path` in a spawn prompt.** Every teammate
  declares `isolation: worktree` and the harness handles their
  working directory. Pass branch name + PR number + issue number
  instead.
- **Never duplicate agent runbooks in spawn prompts.** Trust the agent
  to read its own definition and the per-repo config.
- **Never instruct a teammate to use a closing keyword adjacent to an
  issue reference.** A closing keyword (`close`/`closes`/`closed`/
  `fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`,
  case-insensitive) **immediately followed by** an issue reference
  (`#N`, `owner/repo#N`, `GH-N`, or issue URL) auto-closes the
  referenced issue and must never appear. See
  `rules/git-workflow.md` → "Issue References" for the full rule.
- **Never run subagent worktree cleanup in parallel.** Cleanup is
  serial within a wave, per Anthropic issue #48927.
- **Always wait for explicit human confirmation** before starting
  Phase 2.
- **Max review rounds per PR: 5.** Escalate to human after that. A
  round is one `pr-reviewer` run; the `doc-updater` pass that precedes
  each one is not a review and never counts against the cap.

### What the orchestrator IS allowed to do

The "never do work an agent owns" rule is not a total prohibition on
the orchestrator running commands. The following are orchestration
mechanics, not agent-owned work, and the orchestrator should do them
itself:

- **Read freely.** `gh pr view`, `gh pr diff`, `git log`, `git diff`,
  file reads. Reading is planning; the more the orchestrator reads
  before spawning, the better its spawn prompts. These read-only
  planning commands have **no `/issue-*` equivalent**, so raw `gh` /
  `git` stays the right tool for them. For *reading an issue*,
  however, prefer `/issue-view <N>` over `gh issue view <N> --json
  ...` — see "Prefer the `/issue-*` namespace over raw `gh`" below.
- **Run git plumbing for orchestration mechanics.** `git fetch`,
  `git pull --ff-only` on long-lived branches it tracks (e.g. keeping
  `main` current in the primary clone after a merge),
  `git worktree remove` (without `-f`) for cleanup of a returned
  subagent's worktree, `git worktree unlock <path>` followed by
  `git worktree remove <path>` when the worktree carries the
  harness's stale end-of-run lock (lock reason matches
  `claude agent agent-<hash> (pid NNNN)` and the subagent has
  returned — see `~/.claude/rules/worktree-cleanup.md`),
  `git branch -D` for the same returned-subagent case, `git push`
  of an agent's work that the agent committed but couldn't push
  due to a credential prompt (rare). Force-removal (`-f` / `-f -f`)
  is reserved for data-loss cases (uncommitted changes or unpushed
  commits the user has chosen to discard) and needs explicit human
  approval for the data loss. Any cleanup that touches a worktree
  whose subagent is still mid-run, escalated, or whose lock reason
  does not match the standard harness shape is a human decision
  (see "Never act on a subagent escalation without human input"
  above).
- **Comment on a PR with orchestration metadata** — e.g. "closing
  this PR because we'll respawn the issue", or pointing at a follow-up
  issue. That's coordination, not review. A review body with verdict
  is always `pr-reviewer`'s job. PR comments (`gh pr comment`) have no
  `/issue-*` equivalent, so raw `gh` stays the tool here — but
  commenting on an *issue* goes through `/issue-comment <N>`, per
  "Prefer the `/issue-*` namespace over raw `gh`" below.
- **Manage a PR's draft/ready state and issue link via the
  `/github-prs:*` skills** — `/pr-link-issue <PR> <issue>` (link
  a PR to its own issue) and `/pr-ready <N>` (flip draft → ready at
  end-of-loop). These are coordination metadata in the same bucket as
  `gh pr comment`: they set the PR's lifecycle state, they don't
  author feature work or a review verdict. `/pr-link-issue` is
  idempotent (a no-op when the developer already wrote `Closes #N`),
  and `/pr-ready` merely un-drafts — neither merges the PR. See
  "PR draft/ready lifecycle" below for when the orchestrator calls
  each.
- **Set issue status via `/issue-set-status`** — `In Progress` when
  work starts, `In Review` at end-of-loop. Coordination metadata, not
  agent-owned work. See "Issue-status transitions" below and the
  `/issue-*` namespace rule for the general "prefer the skill"
  principle.
- **File follow-up issues via `/issue-create`.** It sets type,
  priority, size, status, project-board entry, and assignee from
  repo-config in one shot, so the issue is fully configured before the
  URL is printed. Raw `gh issue create` is **not** a substitute —
  issues filed that way come out unconfigured (no type, no slot
  fields, no board entry, no assignee) and require multiple follow-up
  `/issue-set-*` calls to backfill metadata the skill would have set
  in the first place. The skill *is* the right tool for issue
  creation; there is no Task-tool agent for it, but that is no longer
  a reason to hand-roll the raw CLI. If the issue body would be
  long-form and multi-step, ask the human first rather than authoring
  it yourself — that rule is independent of which tool authors the
  issue.

  After `/issue-create` returns, **post-verify with `/issue-view`.**
  Run `/issue-view <new-N>` and confirm that `type`, the configured
  slot fields (`priority`, `size`, `status`), and the assignee are
  populated as repo-config requires. If any required field is empty
  when repo-config says it should be populated, surface the mismatch
  in the final report's **Needs Your Attention** section rather than
  declaring the follow-up issue filed. The check is cheap (one
  `/issue-view` call) and catches the case where `/issue-create`
  silently skipped a step. The post-verify is **not** redundant with
  `/issue-create`'s own output checklist: verifying your own output
  is structurally weaker than having an independent caller verify it,
  and the orchestrator is that independent caller — so it reads the
  issue back rather than trusting the create runbook's self-report.

### PR draft/ready lifecycle

Every PR the orchestrate flow produces goes through the same
draft-first lifecycle:

1. **Born draft.** `issue-developer` creates each PR with `--draft`
   (see its agent definition). A draft PR cannot be auto-merged — the
   repo's auto-merge workflow filters `isDraft == false` — so the PR
   is inert from the moment it opens.
2. **Linked.** Right after the developer reports back, the
   orchestrator calls `/github-prs:pr-link-issue <PR> <issue>` to
   guarantee the PR body closes its own issue (idempotent — see "After
   each issue-developer reports back: link the PR to its issue"). The
   `Closes #N` keyword only fires on merge to the default branch, so
   it stays inert while the PR is draft.
3. **Stays draft through the whole review/fix loop, and through the
   memory scrub that closes it out.** doc-updater, pr-reviewer, and any
   issue-fixer rounds all run against the draft PR, and so does
   `agent-memory-scrubber` — as the last agent to touch the branch,
   re-spawned whenever later work displaces it (see "Before
   `/pr-ready`: curate the PR's agent memory"). Nothing in that
   sequence flips the PR to ready.
4. **Ready at end-of-loop, on human confirmation only.** In Phase 3,
   when the human confirms a PR is good enough to end the loop, the
   orchestrator calls `/github-prs:pr-ready <PR>` (see "End-of-loop
   lifecycle transitions"). This is the single point where the PR
   becomes mergeable, and even then the human — never the orchestrator
   — performs the merge.

The draft state is the enforcement mechanism behind the "Never merge a
PR" Hard Constraint: it makes "unmergeable until the human blesses it"
a property of the PR's state, not just a rule in prose.

### Issue-status transitions

The orchestrator keeps each issue's board status in sync with its
lifecycle via `/issue-set-status`:

- **In Progress** — set after plan confirmation, before spawning the
  issue's developer (Phase 2, "Set each issue to In Progress before
  spawning its developer").
- **In Review** — set on end-of-loop human confirmation (Phase 3,
  "End-of-loop lifecycle transitions").

Both transitions are **gated on a configured status slot**: the repo
must have `github-project.fields.status` (GitHub) or the Jira `status`
slot in `.claude/rules/repo-config.md`. If no status slot is
configured, **warn-and-skip** — emit a one-line note that status
tracking is not configured and continue the run. Do **not** abort;
this matches how `/issue-set-status` itself degrades.

**Option-name fallback.** `/issue-set-status` matches option names
case-insensitively, so `"In Progress"` / `"In Review"` resolve to a
board's `In progress` / `In review` options automatically. But if the
board has a status slot that **lacks** a matching option — i.e.
`/issue-set-status` aborts with its "Slot value not in options map"
error — the orchestrator must **catch that abort and ask the human**
which status option to use instead, or whether to skip the transition
for this run. It must **not** let that abort fail the whole run. This
keeps the feature working on boards whose status options are named
differently (e.g. `Doing` / `Reviewing`).

### Prefer the `/issue-*` namespace over raw `gh`

Wherever a `/issue-*` skill exists for an operation, use it rather
than hand-rolling the equivalent `gh issue ...` or `gh api graphql`
call. The skills read repo-config (via `skills/lib/repo-config.md`),
respect the repo's project board config, dispatch on the issue tracker
(GitHub vs. Jira), and emit the namespace's canonical abort wording —
a raw `gh` call silently does the GitHub-only thing and skips all of
that. This is the same "stop reaching for the lazy raw-`gh` path"
principle behind `/issue-create` above, applied to the rest of the
namespace.

- **Reading an issue** → `/issue-view <N>` (and `/issue-view-tree`,
  `/issue-sub-list` for hierarchy) instead of
  `gh issue view <N> --json title,body,labels`. `/issue-view`
  surfaces type, all configured slot fields, and
  parent/sub-issue/blocked-by/blocking relationships in one shot; an
  ad-hoc `gh issue view --json` misses all of that.
- **Commenting** → `/issue-comment <N>` instead of `gh issue comment`.
- **Closing** → `/issue-close <N>` instead of `gh issue close`.
- **Setting fields** → `/issue-set-status`, `/issue-set-priority`,
  `/issue-set-size`, `/issue-set-type`, and the
  parent/child/blocked-by relationship verbs (`/issue-set-parent`,
  `/issue-set-child`, `/issue-set-blocked-by`, `/issue-set-blocks`,
  and their `unset-` counterparts) instead of raw `gh api graphql`
  issue mutations.
- **Updating title/body/labels/assignees** → `/issue-update <N>`
  instead of `gh issue edit`.

These carve-outs keep this rule from being over-broad:

1. **Read-only planning `gh` / `git` stays.** `gh pr view`,
   `gh pr diff`, `git log`, `git diff`, and file reads have no
   `/issue-*` equivalent and remain the right tools for Phase 1
   planning (see "Read freely" above). This rule is specifically
   about *issue* operations that now have a skill.
2. **No `/issue-*` skill exists → raw `gh` is fine.** When an
   operation has no skill — e.g. a bulk query across many issues, a
   `gh issue list` filter, or a field the namespace doesn't expose —
   raw `gh` remains the tool. The rule is "prefer the skill where one
   exists," not "never touch `gh` for issues."

## Token Efficiency

- Use every teammate with its own frontmatter-declared default
  `model` and `effort` — do not override either on a routine spawn.
  For a genuinely hard issue, escalate that single spawn to a
  stronger model via the `Agent` tool's per-call `model` override
  rather than editing front matter; an override may only raise a
  teammate above its declared default, never lower it.
- Reserve your own model (the orchestrator's) for planning decisions
  and synthesis only
- If the batch is large (>8 issues), split into two separate team
  sessions and note this to the human before proceeding
- **Doing agent work — OR making decisions about an agent's
  lifecycle/environment — in the orchestrator is not a token-saving
  optimization.** It shortcuts the safety mechanism: a teammate's
  perspective on its own task is independent of the orchestrator's;
  the orchestrator's perspective on the same task is not. And the
  human is excluded from decisions the rules reserve for them
  (escalations, locked worktrees, retry-vs-resume). A "quick"
  orchestrator-authored review, fix, or environmental repair loses
  that independence and is worth fewer tokens than it costs.
