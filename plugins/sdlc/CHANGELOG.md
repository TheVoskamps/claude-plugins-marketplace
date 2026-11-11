# sdlc changelog

## 0.78.0 — 2026-11-11

A theorem disprover that cannot settle a claim from the tree and the
commands it can run now reports it `UNSETTLED` rather than `SURVIVED`,
so a survival resting on general knowledge no longer reaches the review
as a checked claim.

- The `UNSETTLED` report carries a `REASON` naming what settling the
  claim needs — a live run, a remote event, a runtime — and a `CHECKED`
  coverage record. Its theorem is disposed
  `unsettled-disprover-unsettled`, which blocks the review and is
  reported as a pipeline defect.
- An `UNSETTLED` report missing either line is malformed, disposed
  `unsettled-disprover-malformed` as before.

## 0.77.0 — 2026-11-08

The theorem-based reviewer no longer writes off a child that is still
running, and stops one it does write off before re-spawning its
theorem.

- A notification saying a child may still be running — one a child
  produces when it ends a turn over background work of its own — is
  interim: the reviewer records no `return` for it and writes nothing
  off. Only a final notification gets a `return`, so `returned-unsaved`
  now means a child that finished without saving. The theorem
  generator, disprover and verifier each never end a turn while
  background work of their own is running.
- Every write-off of a child the reviewer spawned, a `returned-unsaved`
  one included, runs `TaskStop` on that child before its theorem is
  re-spawned: a child that handed back can still be running, and its
  late `leave` would overwrite its replacement's. A child the reviewer
  did not spawn is still never stopped.
- `sdlc-agent-result-persist --mode wait` blocks until a `leave` lands
  in the stage, the earliest awaited child's deadline passes, or there
  is no child to wait on, then prints one line and exits. The reviewer
  runs it in the background before ending any turn that waits on a
  stage, so its run survives a child in the waiting state and it wakes
  at a deadline even when no notification arrives.
- `--mode next` prints a theorem whose child is spawned but has not yet
  entered as `spawned`, never `outstanding`, with the deadline measured
  from its last `spawn`; the reviewer spawns nothing on a `spawned`
  line. A theorem is awaited exactly when its last `spawn` in the stage
  is followed by neither an `enter` nor a `stopped`, decided by the
  order of the records and never by comparing counts. After a `-`
  write-off of a child that never entered, the theorem prints
  `outstanding` again unless an earlier child of it is still in flight.
- The reviewer records every child it spawns with `--mode agent` by the
  id its `Agent` call returned, so a child written off before its
  `enter` still names its worktree for cleanup. `--mode stopped` takes
  `-` as the agent id for such a child.
- The in-flight derivation is stated once and applied alike by
  `--mode print-in-flight`, `--mode next` and `--mode wait`.
- `--mode repos` refuses every flag but `--mode`, with exit 2, before
  it lists anything.

## 0.76.0 — 2026-11-04

`/sdlc:orchestrate` rules on what the repo already settles, the issue
body included, and puts only the rest to you, with its own analysis
beside it.

- A teammate's escalation, a Design Decision a review names, an
  out-of-scope observation and a merge-readiness question each get the
  same check first: a decision the repo settles becomes the
  orchestrator's ruling, quoting the sentence that settles it, and you
  are not asked. What stays open reaches you with the teammate's report
  whole, followed by what the orchestrator checked, which options
  survive, any option missed, and a recommendation, under labels the
  orchestrator assigned.
- A fixer-brief finding line can now end `— in scope: <sentence>` or
  `— settled, no fix: <sentence>`; the `— outside the issue; dropped`
  ending is gone, and `/sdlc:orchestrate-analysis` names each kind.
- Every ruling you give that settles a finding, rejects or changes a
  theorem, overrides a severity, or overrides an issue's requirement a
  theorem tests is posted as a review adjustment before the fixer brief
  that acts on it, so no later round re-files what you settled. An
  override no theorem tests travels in the fixer brief alone, as an
  owner ruling.
- An approved round's Low findings are put to you before the
  close-out, each to leave as it is or file as a follow-up issue, and
  the wrap-up lists them in a table of their own.
- The orchestrator may `Write` and `Edit` files in its session
  scratchpad, where it already keeps run state.

## 0.75.0 — 2026-11-01

Agents keep working under the permission gate's file-work redirect,
now on by default in linked worktrees.

- `pr-finalizer` cuts and reassembles a PR body with the new
  `sdlc-pr-body` script instead of `awk` and a redirected `cat`.
- The new `sdlc-extract-lines` copies a line range between files, and
  refuses a range the source does not reach.

## 0.74.0 — 2026-10-31

Resuming a review round is now deterministic. The persist script
derives the round's arm, each theorem's disposition, class, severity
and state, the verdicts and the posted body. The reviewer runs it and
keeps only the judgment calls. Severity floors and caps on top of the
consequence class are gone.

## 0.73.1 — 2026-10-28

The `[lint-clean]` readiness key now names the `markdownlint-cli2`
binary on `PATH`, because the `npx` form fails where the tool is
installed as a binary.

## 0.73.0 — 2026-10-28

The theorem generator is one agent, spawned with a per-call `effort`.
The `-medium`, `-high` and `-xhigh` definitions are gone, and the
reviewer's `--generator <agent-name>` override is now
`--generator-effort <low|medium|high|xhigh>`.

## 0.72.0 — 2026-10-25

`/sdlc:orchestrate` assesses the seed theorem candidates before asking
you to rule. Each theorem gets a recommended action and a reason, and
coverage gaps come with proposed additions. The recommendations are
advice: only what you adopt takes effect.

## 0.71.0 — 2026-10-21

Documentation gets its own review loop after the code loop, with the
same round rules and a separately counted bound.

- `docs-writer` implements the loop, and `style-checker` and the
  reviewer take `--mode documentation`.
- `/sdlc:git-review-pr` passes a `--mode` through.

## 0.70.0 — 2026-10-19

The issue grammar splits `## Acceptance` into
`## Code and instruction Markdown acceptance`, which the review loop
settles, and `## Documentation acceptance`, which goes to `docs-writer`
rather than sending an implementer at a file it cannot edit. Either
section may stand alone, in any order, so a documentation-only issue can
be orchestrated.

- Readiness gaps: a leftover `## Acceptance`, neither section present, a
  section with no bullet, a bullet spanning both classes or filed under
  the wrong section, and a `### Mechanical` line that is not a bullet or
  its continuation.
- Existing issues are not migrated. `/sdlc:orchestrate-ready` moves a
  leftover section's bullets into the two sections when it grooms one.

## 0.69.0 — 2026-10-18

`/sdlc:orchestrate-cleanup` now runs one script that asks nothing for
a single PR, or sweeps the whole repo with `--all` after one go-ahead.
It replaces `/sdlc:cleanup-interim-work`, and an orchestrate run's
post-merge tail no longer asks a cleanup question.

- `<PR>` removes that merged or closed PR's review state, the worktrees
  and branches of the agents recorded for it, any worktree holding a
  branch the run deletes, its local head branch and its `.claude/tmp/`
  scratch. It refuses an open PR and another repository's PR.
- `--all` removes the repo's review state, every worktree under
  `.claude/worktrees/`, every local branch but the default, all
  `.claude/tmp/` entries and other sessions' scratchpads.
- Removal is forced, so dirty and locked worktrees go too. Nothing on
  `origin` is deleted.
- `--dry-run` lists what would go and removes nothing.
- A real run ends by pruning and fast-forwarding the default branch.

## 0.68.0 — 2026-10-18

File classes now come from the global Claude configuration, and
`sdlc:documentation-definition` is gone. `code-documenter` now covers
comments in instruction Markdown as well as code.

## 0.67.2 — 2026-10-18

`pr-monitor` waits inside foreground script calls and stays in one
turn. Previously a hand-back after each poll could leave several
monitors polling the same PR.

`merge-poll-interval-seconds` is now capped at 540: the config reader
aborts on a higher value. A monitor script error ends the PR's stages
with a row under Needs Your Attention instead of another monitor.

## 0.67.1 — 2026-10-16

Internal rename of an orchestrate procedure file; no behavior change.

## 0.67.0 — 2026-10-13

Every agent but `pr-monitor` now declares `Read`, `Write` and `Edit`,
so agents can follow the direction to use those tools rather than Bash.
`pr-monitor` waits with `Monitor`.

`Skill` leaves every `tools:` list. An agent still gets the skills it
preloads, but can no longer find and invoke others, which keeps it on
task.

## 0.66.0 — 2026-10-12

Git sequences the agents spelled out move to
`git-tools:git-branch-sync`. `issue-fixer` and `agent-memory-scrubber`
use it throughout, and `issue-developer`, `code-documenter`,
`docs-writer` and `style-checker` for their checkout, push or release
steps. Resolving a conflict stays with the agent.

## 0.65.0 — 2026-10-11

A `### Mechanical` bullet now opens with a key from a fixed vocabulary
instead of naming a command. The new `sdlc-readiness-check` grades the
bullets, so text from an issue body never reaches a shell. Only
`[no-match]` runs anything, a grep with the pattern as one argument, and
a path that resolves outside the repo root is refused.

## 0.64.0 — 2026-10-11

The reviewer's definition is roughly halved by removing restatements
and rationale; behavior does not change.

## 0.63.1 — 2026-10-11

The agents and plan stop restating the issue-branch grammar and slug
rules, which `git-tools` now owns. The reviewer's `--issues` takes `N`
or `#N`, space-separated; comma-separated lists are gone.

## 0.63.0 — 2026-10-08

`pr-finalizer` posts a PR's review detail with one call to the new
`sdlc-pr-post-theorem-records`, replacing piece-by-piece retyping into
scratch files.

## 0.62.0 — 2026-10-08

Review children are written off sooner and more accurately.

- A child that returns without its `leave` is written off when its
  notification arrives, not after the deadline.
- A `stopped` record names the child it writes off, so a late one
  cannot write off a replacement.
- A generator's `leave` refuses colliding new ids while it can still
  renumber.

## 0.61.0 — 2026-10-08

Fixed PR and branch reads that agents assembled by hand are now scripts
(`sdlc-pr-round`, `sdlc-pr-adjustments`, `sdlc-fixer-brief`,
`sdlc-records-chain`) or the new `github-prs:pr-files` and
`git-tools:git-range`. The reviewer no longer removes spawned worktrees;
that is left to `/sdlc:cleanup-interim-work`.

## 0.60.0 — 2026-10-05

`sdlc-agent-result-persist` names a PR by one
`--pr <host>/<owner>/<repo>#<n>` reference in place of `--repo` and a
bare number, and `--mode list` prints that form. `--mode list` takes
its repository as an optional operand, and
`/sdlc:orchestrate-cleanup` passes the same optional repository through.
`/sdlc:git-review-pr` and `/sdlc:orchestrate-analysis` accept any PR
form `pr-view` does.

## 0.59.0 — 2026-10-04

Every `gh` call targets the repository's own host, so a checkout on a
GitHub Enterprise host no longer fails. Review state now sits under
`sdlc/<host>/<owner>/<repo>/`, and the persist script moves existing
state there on its first run, refusing if state exists at both paths.
`/sdlc:orchestrate-cleanup` asks you for the host of an old-layout
directory, offering `github.com`, and reports a directory whose
`repo.yml` names another path.

## 0.58.1 — 2026-10-04

A review child's staged report name now includes the round, so a later
round in the same session cannot find the earlier round's report.

## 0.58.0 — 2026-10-04

The persist script now builds a round's carried records, so the
reviewer no longer needs a program the auto-mode classifier denies. The
generator reads carried records from state rather than from its brief.
A round whose previous head can no longer be fetched still carries the
stored records.

## 0.57.0 — 2026-10-03

The files-affected list is a floor, not a ceiling. The pre-review scope
gate fires only on a plugin the issues do not name or a rename or
deletion they do not specify. Instruction Markdown becomes a file class
of its own, edited by the implementers rather than `docs-writer`. An
implementer reports a documentation edit it owes on a fixed
`Deferred to docs-writer:` line, which goes to `docs-writer` rather
than to you.

## 0.56.0 — 2026-09-28

`/sdlc:orchestrate-ready` now files a side-effect issue in another
repo with `/issue-create --repo` instead of a raw `gh` call.

## 0.55.0 — 2026-09-27

`/git-cleanup-branches-and-worktrees` moves here from `git-tools` as
`/sdlc:cleanup-interim-work`, so `git-tools` no longer needs a
dependency on `github-prs`. It indexes what runs leave behind in the
repo (`.claude/tmp/` scratch, harness scratchpads, worktrees, and local
and remote branches), grades each item, asks which to remove and removes
only those. `--index-only` reports without removing.

Every PR call in the agents and skills now goes through a `github-prs`
verb, and `/sdlc:orchestrate-cleanup` uses the moved sweep.

## 0.54.0 — 2026-09-27

`pr-merge-readiness` now sends a `DIRTY` PR to `issue-fixer` as it does
`BEHIND`. You get a conflict question only when the fixer could not
resolve the conflict.

## 0.53.2 — 2026-09-26

An in-scope review finding goes straight to the fixer. The reviewer no
longer offers a rejection alternative or asks you to confirm intent.
You can still reject a finding through an adjustment comment.

## 0.53.1 — 2026-09-26

`leave` refuses a disprover or verifier report that answers a different
theorem, which previously could stop a round from approving.

## 0.53.0 — 2026-09-26

Theorem agents persist reports from a file named with `--from` instead
of a heredoc. Reports quoting `git` text were being refused by the
harness's worktree-isolation guard.

## 0.52.0 — 2026-09-26

`/sdlc:orchestrate-ready` resolves status options through
`/issue-field-options` instead of reading the repo config itself. This
also makes it work on a Jira repo, and it stops when the status slot is
unconfigured.

## 0.51.0 — 2026-09-24

`pr-finalizer` reaches review state only through the persist script and
`Read`, never a raw shell command, and sizes detail chunks in scratch
files. It reports a gate refusal as the refused command, the gate's
message and the route taken, never as a claim about a tool.

## 0.50.1 — 2026-09-24

The developer's brief now asks for design decisions it stopped on, with
options, rather than decisions it made.

## 0.50.0 — 2026-09-23

The readiness check grades `### Mechanical` bullets against the tree, so
the same body and tree always get the same verdict.

- A bullet asserting absence is run, read-only. A site it reports is a
  gap unless its file is tagged `update` or `delete` under files
  affected.
- A bullet requiring presence is not run, since it fails before
  implementation. It is a gap unless its target file is listed.
- A bullet whose check would write to the tree is a gap.

## 0.49.0 — 2026-09-22

`/sdlc:orchestrate` fixes style findings without asking fix-or-ignore.
A finding pauses for you only when its rule cannot settle it: the last
fixer left it unfixed, it came back after a fix, or the rule would
contradict the issue. An ignore holds for the rest of the PR's loop.
`/sdlc:orchestrate-analysis` also reports rulings on findings that name
no theorem.

## 0.48.1 — 2026-09-22

A shared-helper edit the issue specifies now passes the scope gate
without a question. An unspecified one still comes to you.

## 0.48.0 — 2026-09-22

The seed ruling, merge wait and monitor poll bounds are configurable
through global user, shared repo and repo user YAML tiers, written by
`/sdlc:sdlc-config-global`, `/sdlc:sdlc-config-repo` and
`/sdlc:sdlc-config-user`. Defaults match the earlier behavior.

## 0.47.0 — 2026-09-22

Adds `/sdlc:orchestrate-analysis <PR>`, a read-only report of where an
orchestrate run's wall-clock time went.

## 0.46.1 — 2026-09-22

Each theorem generator now states its own name and tier, so a low-tier
spawn can no longer file its list under another tier's name. The review
reports the tier the generator recorded, and names both tiers when that
differs from the one spawned.

## 0.46.0 — 2026-09-22

Adds `/sdlc:orchestrate-cleanup`, which deletes the review state of
merged and closed PRs and then sweeps merged branches and stale
worktrees.

## 0.45.1 — 2026-09-22

Removes restated agent-memory contracts from the agents; behavior does
not change.

## 0.45.0 — 2026-09-21

The orchestrate skill loads each phase's procedure only when its moment
arrives. The polling loops become the `pr-merge-readiness` and
`pr-monitor` agents.

## 0.44.0 — 2026-09-19

A PR's close-out is gated on merge readiness and can be re-run. The
flow loops until the gate passes, replaces the finalizer's section
rather than stacking it, and watches the PR until it merges.

- `CLEAN` and `UNSTABLE` proceed. `BEHIND` goes to `issue-fixer` to
  rebase without asking. `DIRTY` shows you the conflicts and asks.
- `BLOCKED` stops and reports, unless a missing review is its only cause,
  which proceeds, or it lists only running checks, which it waits on.
- The flow polls every 120 seconds and asks after 15 unchanged polls.
- Confirmed PRs close out one at a time. After the last, the run cleans
  up once and returns the primary clone to the default branch.

## 0.43.1 — 2026-09-17

Reorganizes the orchestrate skill, naming its phases by heading and
moving the agent-memory scrubber section to where it applies.

## 0.43.0 — 2026-09-17

Adds `sdlc:orchestrate-readiness`, the one owner of the readiness bar,
the issue-body grammar and the gap-list check. The bar gains a
files-affected item.

`/sdlc:orchestrate` now runs the check on every issue first. An issue
below the bar stops the run before any branch or PR, printing its gaps
and naming `/sdlc:orchestrate-ready`.

## 0.42.0 — 2026-09-16

`/sdlc:orchestrate` seeds the theorem set from the issues and asks you
to rule on it before the developer runs, so work beyond the issues
shows up against a list you already own. You accept, reject, re-mode or
merge each theorem. `/sdlc:orchestrate-ready` adds a
`## Files affected (floor)` section to the bar for the seed to read.

## 0.41.0 — 2026-09-16

`code-documenter`, `docs-writer` and `style-checker` are narrowed to
what each reads and writes, leaving claim verification to the review
pipeline. `style-checker` takes rules only from a guide's
`## For Authors and Checkers` section. It and `code-documenter` report a
global guide they cannot read rather than checking nothing silently.

## 0.40.0 — 2026-09-15

`class` is split into `settle-mode` and `CONSEQUENCE-CLASS`. A token in
the wrong slot could previously drop a theorem out of severity
derivation and still report `APPROVED`.

- A report with an absent or unknown consequence class is malformed. A
  finding whose class cannot be derived is filed at High.
- An unsettled theorem now blocks approval: the review reports it as a
  pipeline defect and the verdict is `BLOCKED`.
- The verifier re-reads every quote at the round's own head and rejects
  one that is absent there.

## 0.39.0 — 2026-09-15

Acceptance-criterion theorems persist across rounds and retire like
any other, and a human rejection or severity override holds for the
rest of the PR.

## 0.38.0 — 2026-09-15

The issue's acceptance section becomes the ceiling of the fix loop,
enforced through scope slots. The orchestrate skill is also cut by
removing what other files state, and the reviewer's report ends in a
fixed `Return:` line.

## 0.37.0 — 2026-09-11

`doc-updater` is replaced by `code-documenter` and `style-checker`,
which run before each review, and `docs-writer`, which runs once after
you confirm the loop has ended. Documentation leaves the review loop.

## 0.36.0 — 2026-09-10

Theorem records and argued reviews live under XDG state. The posted
review shrinks to an index, avoiding GitHub's comment cap, and the full
detail is posted to the PR once when the fix loop concludes.

## 0.35.0 — 2026-09-10

`/sdlc:orchestrate-ready` now requires an `## Acceptance` section whose
bullets are claims a reviewer can try to disprove, and tightens what
counts as self-contained.

## 0.34.0 — 2026-09-09

An out-of-scope observation is ruled on while the PR is open, not held
for the final report, and becomes a follow-up issue only if you ask.
Each batch's issues are also assigned to the default assignee when
their developer starts, even in a repo with no status slot.

## 0.33.0 — 2026-09-08

The review round log moves to XDG state, keyed by owner, repo and PR,
so a new session can resume a round. `--scratchpad` is gone.

## 0.32.0 — 2026-09-04

`/sdlc:orchestrate` no longer removes and narrates worktrees as each
teammate returns; it runs the `git-tools` cleanup sweep once at the end.
That sweep does not reach a worktree left at a detached HEAD, so at this
version a run reclaims no teammate worktree that released its branch.

## 0.31.2 — 2026-09-02

Theorem generation names the style guides at their current paths. Stale
paths had silently produced no style theorems.

## 0.31.1 — 2026-09-02

`agent-memory-scrubber` may land transfers in any of the repo's
documentation files, not only `CLAUDE.md` and `docs/`, and reports
which files it created.

## 0.31.0 — 2026-09-01

A stalled review round resumes from its record file instead of
restarting, keeping the theorems it already settled. If the PR's head
moved, the round is set aside rather than mixing verdicts from two trees.

## 0.30.0 — 2026-08-27

Review children persist their own results outside every worktree, so a
lost task notification no longer loses a result. One notification that
arrives carries the round past every lost one; if none arrives, nothing
wakes the reviewer. This adds the `sdlc-agent-result-persist` script.

A re-spawned reviewer now stops on the existing record rather than
restarting the round from nothing.

## 0.29.1 — 2026-08-26

The reviewer appends to its round state file instead of rewriting it
from memory, which had left returned disprovers uncounted.

## 0.29.0 — 2026-08-27

Guidance from the repo's top-level instructions moves into this
plugin's README, with references in the agents and skills updated.

## 0.28.0 — 2026-08-26

The reviewer posts through `pr-review-submit --verdict`: `APPROVED` as
`approve`, and `NEEDS_CHANGES` and `BLOCKED` as `request_changes`.
A self-review downgrade is now that skill's job.

## 0.27.0 — 2026-08-26

The review loop can now converge. Rounds keep a state file so they no
longer hang mid-fan-out, a finding fixed by a PR-body edit can clear,
and a cleared acceptance criterion stays cleared.

## 0.26.0 — 2026-08-25

`doc-updater` applies the instruction-Markdown retention test to what
is already in a file it touches and deletes what fails, rather than
only appending. `agent-memory-scrubber` relays what curation cut from
destination files and verifies against the skill's `Commit:` line.

## 0.25.0 — 2026-08-24

Follows the `issues` plugin's config files to their new paths under
`.issues/` and `$XDG_CONFIG_HOME/issues/`.

## 0.24.1 — 2026-08-23

The verifier wait is bounded at 15 minutes, so a verifier that never
reports can no longer park a round.

## 0.24.0 — 2026-08-22

The disprover wait is a stated, bounded resume loop. A partial tally no
longer ends a round, and a child that dies cannot park one. This also
closes a loophole in the generator tier rule.

## 0.23.0 — 2026-08-22

The reviewer can stage its review body to a file, so a body too large
for a command-line argument can post.

## 0.22.1 — 2026-08-20

Theorem agents now rely on the permission gate to deny primary-clone
reads, and their guidance focuses on extracting evidence from `HEAD`
rather than another ref.

## 0.22.0 — 2026-08-20

Re-review rounds converge. The theorem list persists across rounds with
stable ids, and each round works from the commits added since the last.

- A theorem that survives retires. `--full` re-attacks every recorded
  theorem, since a default round never re-checks a retired one.
- Your adjustments reach later rounds only as a PR comment the
  orchestrator posts.
- Review is now the `theorem-based-pr-reviewer` agent, which both
  `/sdlc:orchestrate` and `/sdlc:git-review-pr` spawn.
- The generator defaults to low effort, with medium by rubric. High and
  `xhigh` come only from `--generator`.

## 0.21.0 — 2026-08-19

Agent memory no longer travels on the issue branch. Writers copy it to
a session inbox, and `agent-memory-scrubber` transfers what is durable.

## 0.20.1 — 2026-08-19

Theorem disprovers and verifiers must read inside their own worktree,
because a primary-clone read returns plausible pre-branch content.

## 0.20.0 — 2026-08-19

Style guides become a theorem source, so style findings arrive
reproduced and verified like any other.

## 0.19.0 — 2026-08-19

The fixer's methods move into `issue-fixer`, which previously never
read them. Duplicated contracts and briefs are removed.

## 0.18.2 — 2026-08-18

`theorem-disprover` and `counterexample-verifier` gain `WebFetch` and
`WebSearch`, so a claim resting on an external source can be settled.

## 0.18.1 — 2026-08-18

Removes foreground-only spawn guidance, since subagents now run only in
the background.

## 0.18.0 — 2026-08-17

Adds `/sdlc:orchestrate-ready`, which grooms one issue to the bar
`/sdlc:orchestrate` needs, and the plugin's README.

## 0.17.0 — 2026-08-13

Theorem generation adds a stakes question after falsifiability, so
true but inert claims are not emitted. Generator tiers are picked by
blast radius.

## 0.16.0 — 2026-08-13

Every disproved theorem now gets an adversarial `counterexample-verifier`
before it can become a finding. The posted review becomes an argued
report, and severity is transcribed from a consequence class.

## 0.15.0 — 2026-08-12

The orchestrator's spawn prompts may no longer pre-solve the task, and
new rules govern how it consumes teammates' reports.

## 0.14.0 — 2026-08-11

PR review is rebuilt as a theorem pipeline: a generator states
disprovable claims, parallel disprovers each try to break one, and
severities and verdicts follow mechanically. This replaces the
checklist-driven `pr-reviewer` agents.

## 0.13.0 — 2026-08-06

The review protocol moves into a preloaded skill, with effort-tier
reviewer variants on top of it.

## 0.12.0 — 2026-08-06

`issue-developer`, `issue-fixer` and `pr-reviewer` now default to
`effort: medium`, making it the whole fleet's declared effort.

## 0.11.0 — 2026-08-03

`/sdlc:orchestrate` supports batches: an ordered set of issues on one
branch, delivered as one PR that closes them all. A single issue is a
batch of one and behaves as before.

## 0.10.0 — 2026-08-02

`doc-updater` runs after every `issue-fixer` round, and agents must
verify prose claims about how code works against the code. A pass with
no documentation impact commits nothing, and only `pr-reviewer` runs
count toward the review-round cap.

## 0.9.2 — 2026-08-02

`issue-developer` and `issue-fixer` may use the harness scratchpad, but
only for a file that must outlive the repo or session.

## 0.9.1 — 2026-08-01

`agent-memory-scrubber` now runs after whatever touches the branch
last, rather than exactly once after the last review.

## 0.9.0 — 2026-07-30

Raises agent defaults: `issue-developer` and `issue-fixer` to `opus` at
`xhigh`, `pr-reviewer` to `fable` at `xhigh`, and `doc-updater` and
`agent-memory-scrubber` to `opus`. Explicit spawn arguments still
override these.

## 0.8.0 — 2026-07-25

Adds `agent-memory-scrubber`, which curates agent memory after every
writer has captured. Curation moves out of `doc-updater` into the
`cc-tools` `/agent-memory-cleanup` skill the new agent runs, so the
plugin now depends on `cc-tools`.

## 0.7.0 — 2026-07-16

`pr-reviewer` grades severity by consequence, separates non-findings
from findings, and cannot approve over an open Critical, High or Medium
finding. The orchestrate fix loop is widened to match: `issue-fixer` runs
on every `NEEDS_CHANGES` and addresses every finding, Low included, and
the review-round cap rises to 5.

## 0.6.0 — 2026-07-16

Branch creation now comes from `git-tools:git-branch-create`, and the
plugin depends on `git-tools` in place of the retired `gh` plugin.

## 0.5.0 — 2026-07-16

Branch and PR mechanics move out to the new `gh` and `github-prs`
plugins. Agents invoke their skills instead of parsing the repo config,
and the plugin's own repo-config reader is removed.

## 0.3.3 — 2026-07-13

Agent memory no longer vanishes with worktrees. Writers commit their
raw entries to the branch, and `doc-updater` curates them. `pr-reviewer`
runs after `doc-updater`, so its entries are curated one PR late.

## 0.3.2 — 2026-07-11

Removes the unhonored `permissionMode` key and stale tool names from
agent front matter; behavior does not change.

## 0.3.1 — 2026-07-11

Pins `effort` on all agents so they stop inheriting the spawning
session's level: `doc-updater` at `medium`, the others at `high`.

## 0.3.0 — 2026-07-09

`issue-developer`, `issue-fixer` and `doc-updater` move to `sonnet`;
`pr-reviewer` stays on `opus` as the verification gate.

## 0.2.0 — 2026-07-09

`doc-updater` gains writing-style and in-code documentation rules, so
its commits can now touch source files as well as Markdown.

## 0.1.0 — 2026-06-22

The plugin at the initial snapshot: the `/sdlc:orchestrate` flow and
`/sdlc:git-review-pr`, with the `issue-developer`, `issue-fixer`,
`doc-updater` and `pr-reviewer` agents.
