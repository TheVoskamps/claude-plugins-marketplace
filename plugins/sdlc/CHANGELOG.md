# sdlc changelog

## 0.91.0 — 2026-11-20

An `/sdlc:orchestrate` run now pins one status line under the prompt,
showing where the run is:

```text
PR #812 · code loop r2 · theorem-based-pr-reviewer › disprove 15/31 theorems
```

- The line names the PR the run is on, the phase it is in —
  `readiness`, `plan`, `seed`, `develop`, `code loop`, `doc loop`,
  `memory scrub`, `merge readiness`, `finalizer`, `monitor` or
  `cleanup` — and the agents running, a name running more than once
  written as `<name>×<n>`. A part with nothing to show is left out.
- During a review round, `code loop` and `doc loop` carry the round as
  `r<round>`, and the reviewer is followed by the round's stage, with
  the theorems settled out of those in the stage during `disprove` and
  `verify`. The round stays with its loop: the documentation loop shows
  no round until its own first reviewer runs, and a PR that returns to
  a loop shows that loop's round again.
- Any other agent with running children is followed by their names.
- Every other PR that still has a running agent follows as
  `| #<n> <phase>`, or as `| #<n>` when nothing has set a phase for
  it.
- The line appears when `/sdlc:orchestrate` is invoked, and in a
  session resumed mid-run from the next agent the run spawns. It is
  redrawn as the run moves and every 5 seconds while an agent is
  running, and cleared when the run's cleanup ends or the session does.
  A standalone `/sdlc:git-review-pr` shows no line.
- `/orchestrate-status off` turns the line off, `on` turns it on, and
  no argument flips it. The command runs while a turn is in flight and
  costs no model turn. The line is on when a session starts, and the
  choice lasts the session.

`sdlc-agent-result-persist` gains `--mode progress --pr <ref>`, the
read the line takes a round's progress from: one tab-separated line
giving a PR's latest round, its type, its stage and how many of the
stage's theorems are settled, and nothing for a PR with no round log.

`hooks/hooks.json` now names one module, `hooks/register.ts`, which
registers the plugin's hook files, since the hook engine takes one
module per plugin.

## 0.90.0 — 2026-11-19

The readiness bar gains two items, and `/sdlc:orchestrate-ready` now
asks the human only the design decisions a body leaves open, and sets
an issue Ready only once each has the human's answer.

The readiness bar:

- **Outcome, not method** fails a body that prescribes implementation
  steps instead of outcomes: a fix per finding of a linter, type
  checker, test run or scanner, a file and line given as where to make
  a change, or a tool's diagnosis stated as fact. A config file's
  content, a name, a placement, a policy, an interface a consumer
  depends on, and an observable outcome such as "the tool reports
  clean" all still pass. Grooming restates each failing sentence as its
  outcome, without a question.
- **No contradicted repo statement** fails a body that specifies
  something a `CLAUDE.md`, a file under `docs/rules/`, a skill, an
  agent file or a touched plugin's root `README.md` forbids, unless the
  body says the statement is deleted, replaced with given text, or
  given a named exception with its reason. The check searches those
  files on every run and reports what it searched on a `Searched:` line
  ahead of the gaps.
- A gap with only one possible repair is labelled `mechanical:` — an
  `## Acceptance` section, the acceptance headings missing beside one,
  a sentence failing "Spec quality", and a files-affected list under a
  level-2 heading other than `## Files affected (floor)`. A mistitled
  list is recognised only under a level-2 heading naming files
  affected, over items that open with a backticked path or end in a
  files-affected tag, and its bullets are then read as the list.

Grooming, `/sdlc:orchestrate-ready`:

- A design question's record must now name the existing pattern: the
  `path:line` in the repository that already does the thing, or the
  exact search that found none. `sdlc-decision ask` refuses a
  `design-gap` problem without it and prints it in the question as
  `Existing pattern:`. A pattern that exists is option 1 and the
  recommendation, unless the reason given says why it does not fit.
- Mechanical gaps and "Outcome, not method" gaps are repaired in the
  rewrite and listed in the final report, with no question.
- No question is raised about a system the repository holds no source
  or config for, such as another repository or a remote backend. The
  body states in one sentence what the change assumes of it. A "Sandbox
  fit" gap is handled the same way, and the out-of-repo work it removed
  is offered as a side-effect issue.
- A "Self-contained" or "Dependency posture" gap is put to the human,
  and the body is changed only as the answer says.
- The rule against a multiple-choice form is gone: every design gap is
  a decision record with two to four options, and the options of a
  decision too open to enumerate are candidate proposals. An answer in
  free text is still accepted.
- The status is flipped only when the readiness check passes and
  `sdlc-decision pending` finds no design gap waiting on an answer. A
  body that passes the check on the skill's own proposed text is no
  longer enough.
- A design gap a reply left unanswered is asked again on its own
  record, at the start of the next session included, instead of in a
  new record.
- New config key `ready-rewrite-approval`, `ask` or `auto`, default
  `ask`. Under `auto` the closing approval of the acceptance criteria
  and the files-affected list is skipped once every design gap is
  answered, and the skill prints what it wrote.

A contradicted repo statement during `/sdlc:orchestrate`:

- `issue-developer` and `issue-fixer` no longer settle a conflict
  between an issue and a rule the repo chose. They stop and report the
  statement and its file, and the orchestrator puts it to the human
  with the issue edit inside each option.
- A statement about what the harness or a tool can do is deleted, with
  every restatement of it, only after a read-only test showed it false,
  and the test and its output are reported. One that is not tested, or
  not shown false, goes to the human like a rule.
- The plugin carries this rule itself. The section of this
  marketplace's root `CLAUDE.md` that had the implementer settle such a
  conflict inside the PR is removed.

`sdlc-decision`:

- New mode `pending (--pr <ref> | --issue <ref>)` exits 4, naming each
  one, while a `design-gap` problem has no ruling and no answer, and 0
  otherwise.
- New mode `question (--pr <ref> | --issue <ref>) --decision <n>`
  prints a record's question again, exactly as `ask` printed it. `ask`
  now stores the question beside the record. For a record stored before
  this version, `question` renders the same text from the record, which
  needs `yq`.
- `answer` accepts a record again while any of its problems is still
  open, and records picks only for those. Each reply is appended to the
  stored replies, starting on a line of its own.
- `answer` stores its files whole or not at all, and reports a failed
  write as `cannot store <path>`, as `ask` does.

The `reload-after-compact` hook now reloads the readiness skill for the
whole of an orchestrate run, where it used to drop it once the run's
first agent was spawned.

## 0.89.0 — 2026-11-18

After a compaction, the `reload-after-compact` hook's reload message
is drawn on screen as one summary line, instead of a row holding the
full text of every reloaded file. The model still receives the full
text.

- The line reads
  `sdlc: reloaded <A> files (<T>k tokens) after compaction`, followed
  by `; <B> not appended`, `; <C> unreadable` and `; state file failed`,
  each only when it applies. `<A>` counts the files appended, `<B>`
  those past the reload budget and `<C>` those that could not be read,
  and `<T>` is the appended text in tokens, counted as characters ÷ 4
  and rounded to the nearest thousand. It is drawn dim, on every
  surface.
- Every other user message is drawn as before.
- In the reload message's list of files, each entry now states its
  status ahead of its path: `- (appended below) <path>`,
  `- (not appended: read it before acting on it) <path>` or
  `- (could not be read: <error>) <path>`. Before this version the
  path came first.
- Every path and error text in that list, and every state-file error
  in the message's `State:` paragraph, is now written on one line, its
  lines joined with ` | `.

## 0.88.0 — 2026-11-18

Every question `/sdlc:orchestrate` and `/sdlc:orchestrate-ready` put to
the human now goes through a checked decision record with numbered
options, and an unconfigured run no longer stops for a finding outside
the issue it can fix in the PR, or for a finding class that recurs.

Needs `issues` 0.15.0, and mikefarah `yq` v4 or later on `PATH`.

Changed behaviour with no config. To get the old questions back, set
either key to `ask` with a `sdlc-config-*` verb:

| Key | Values | Default |
| --- | --- | --- |
| `outside-criteria-finding` | `ask` \| `fix-in-pr` | `fix-in-pr` |
| `recurring-finding-class` | `ask` \| `fix-class` | `fix-class` |

- New executable `sdlc-decision`. `ask` takes a YAML record of the
  problems one turn raises. Each problem carries a class, a problem
  statement, two to four options, one recommended option and the
  reason for it, and each option carries what it does, its evidence
  and its cost to the human. `ask` refuses a record with a slot empty
  or malformed, naming every failing slot, and checks that a `file:`
  evidence's quote is on the line it names. It never runs a `command:`
  evidence.
- A question is printed with its problems numbered `P1`, `P2`, … and
  each problem's options `P1.1`, `P1.2`, …, so a reply of option ids
  maps to one option per problem. The human can still answer in their
  own words.
- `sdlc-decision answer` stores the option picked for each problem and
  the reply verbatim, and `sdlc-decision print` lists the stored
  records of a PR or an issue. Records are kept under
  `${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/<host>/<owner>/<repo>/`,
  in `pr<N>/decisions/` for a PR and `issue<N>/decisions/` for a
  grooming session or a batch whose PR is not open yet.
- Every remaining question either skill asks goes through
  `sdlc-decision`: a plan's decision items, a developer's out-of-scope
  change, a paused style finding, a design decision, a relayed
  escalation, a loop's end, and whether to keep waiting on a merge. A
  plan that carries decision items ends on that question in place of
  `Ready to proceed?`, and the reply also confirms the plan. The plan's
  own confirmation prompt and the per-theorem seed rulings under
  `seed-review: ask` keep their shapes.
- A problem never has fewer than two options or more than four. A
  longer list of candidates is shown as the three ranked first, beside
  an option to name another or, for a decision the human can decline,
  to skip it. A list of one is taken as the pick, with no
  question and no record, unless the decision is one the human can
  decline.
- A decision can be declined only where the skill asking it states
  what skipping it does, and then one of its options is that outcome.
- `/sdlc:orchestrate-ready` resolves the sdlc config before its first
  question and prints each value beside its tier. Its grooming
  questions are decision records too; a free-text answer is stored
  beside the pick `none`.
- New standing ruling `outside-criteria-finding`. Under `fix-in-pr`,
  the default, a finding whose fix lies outside the issue's acceptance
  criteria, or an observation no review filed, is fixed in the PR with
  no question, and the issue is edited where the fix departs from its
  text. That applies only when every file the fix touches is in this
  repository, the PR is still a draft, and the orchestrator can name
  one fix with no condition attached, backed by evidence. Any other
  such finding is still put to the human.
- New standing ruling `recurring-finding-class`. Under `fix-class`,
  the default, a finding class filed on two consecutive rounds gets
  one fixer brief covering every instance of the class, with no
  question. A class that recurs again after that brief is put to the
  human.
- A decision a standing ruling resolved is named in the report of the
  round that resolved it, and the PR's final section records it as
  that config key's ruling.
- A finding still open at a loop's round cap now reaches the human
  only as that loop end's decision, which lists each open finding. It
  is no longer a Needs Your Attention row of the run summary, which
  reverses the 0.83.0 change that made it one. A PR still draft at the
  end of the run because of a pick at a loop's end is listed under a
  new Left Draft table with that pick; one that later went ready or
  merged is listed where that state puts it.
- New config keys `follow-up-issue-type`, `follow-up-issue-priority`,
  `follow-up-issue-status` and `follow-up-issue-assignee`, each
  defaulting to `repo-default`: the fields a follow-up issue the human
  ordered is filed with when the order named none. `repo-default` uses
  the target repository's own default and asks nothing, except for a
  priority or status slot configured with no default. `ask` makes the
  field a question. The assignee key also takes `@me` and `none`,
  which files the issue unassigned.
- When a follow-up issue's type or assignee is asked and the human
  declines, a declined type gets whatever type `/issue-create`
  resolves, and a declined assignee files the issue unassigned.
- Pre-flight prints every new key beside the tier it came from, and
  the `sdlc-config-*` verbs offer them.
- `/sdlc:orchestrate-analysis` reports a Decisions table: per class,
  the questions asked, the records a standing ruling resolved, the
  picks equal to the recommendation, the picks that differ, and the
  answers in free text. It counts the records of the PR, of each issue
  the PR closes, and of each issue its branch names, so a member
  dropped from the PR is still counted.
- `sdlc-decision ask` moves review state from the layout that predates
  the host segment, and writes `repo.yml`, exactly as
  `sdlc-agent-result-persist` does. When that move cannot remove a
  directory it emptied, the failure is now reported and the move still
  succeeds; it used to pass unreported.
- `sdlc-decision print` handles a state path that contains a newline.

## 0.87.0 — 2026-11-17

An unconfigured `/sdlc:orchestrate` run now applies the seed
assessment's recommendations instead of setting them aside, and
`pr-finalizer` corrects PR-body claims the branch contradicts whether
or not a teammate reported them.

Changed default. To keep the old behaviour, set `seed-review:
accept-as-emitted` with a `sdlc-config-*` verb:

| Key | Old default | New default |
| --- | --- | --- |
| `seed-review` | `auto-accept` | `accept-recommended` |

- `seed-review` takes one of `ask`, `accept-as-emitted` and
  `accept-recommended`. `ask` is unchanged: the run shows the seed
  candidates with `theorem-assessor`'s assessment and waits for the
  human's rulings. `accept-as-emitted` is what `auto-accept` did: it
  shows both, accepts every candidate as the generator emitted it, and
  applies no recommendation. `accept-recommended`, new and the default,
  shows both, applies every recommendation — rejects, settle-mode
  changes, merges, splits, rewrites and coverage-gap adds — and
  continues without waiting. Before this version no value applied the
  assessment without a wait.
- `auto-accept` is a deprecated alias for `accept-as-emitted`. A config
  file that sets it keeps its behaviour, pre-flight prints the value as
  `accept-as-emitted` and names the alias beside its tier, and a
  `sdlc-config-*` verb that rewrites the file writes
  `accept-as-emitted` in its place.
- That a seed recommendation applies only when the human adopts it
  still holds under `ask`. `accept-recommended` is the one exception:
  choosing the value adopts every recommendation in advance.
- Under `accept-recommended`, a seed theorem the assessment rejected or
  merged away is recorded as retired with `state-detail:
  assessor-rejected`, and a claim the assessment wrote — by a merge, a
  split, a rewrite or an add — carries `minted-by: assessor`, as on a
  review round.
- Round 0's log carries a new record under `accept-recommended`,
  `seed-review <instant> accept-recommended`, marking the whole seed as
  applied by recommendation. `sdlc-agent-result-persist --mode
  seed-review --round 0 --value accept-recommended` writes it, and is
  refused at any other round and with any other value. Under `ask` and
  `accept-as-emitted` round 0's log is unchanged.
- Where round 0's log carries that record, `/sdlc:orchestrate-analysis`
  lists the seed's rulings as applied by recommendation under config,
  quotes no human reply for them and labels no wait as the seed
  ruling, and the PR's final section attributes the seed's rulings to
  the recommendations rather than to the human.
- `pr-finalizer` checks every factual claim in the PR body above its
  own section — what the change does, and which identifiers, queries,
  files and settings it uses — against the branch at its head and the
  round records. Each claim that evidence contradicts is listed under
  "Corrections to the body above", quoted, with what is true now and
  the commit or round that shows it. Before this version only a stale
  claim a teammate's report named was corrected, so a claim a later
  fixer round falsified could reach the merged PR uncorrected. The
  body above the section is still never rewritten, a claim the
  evidence neither confirms nor contradicts is left alone, and a claim
  a report also named is listed once.

## 0.86.0 — 2026-11-17

Every theorem list a generator produces is now assessed by a new
agent, `theorem-assessor`, before any disprover runs. Before this
version only the seed list was assessed, by the orchestrator itself,
so a duplicate, a compound claim, or a claim that only a run of the
merged change could settle went to a disprover unchallenged on a
review round.

- New agent `theorem-assessor`. It recommends one action per theorem —
  accept, reject, change settle mode, merge, split or rewrite — and
  proposes a theorem for each acceptance criterion or stated behavior
  no theorem tests. Beyond what the seed assessment judged, it asks
  whether a disprover can settle the claim before merge, from the
  branch's tree and commands it can run locally.
- At the seed, `/sdlc:orchestrate` spawns the assessor instead of
  assessing the list itself. What the human sees and rules on is
  unchanged, and so are both `seed-review` values: `auto-accept` still
  shows the assessment and applies none of it.
- On a review round, the reviewer spawns the assessor on the theorems
  the round's generator emitted and applies every recommendation
  without asking. The posted review lists each recommendation applied
  other than an accept. A round with no delta and no new adjustment
  comment spawns neither agent, and a theorem made from an adjustment
  comment is never assessed.
- A theorem the assessor rejected or merged away is recorded as
  retired with `state-detail: assessor-rejected`. A `--full` round
  disproves it again, as it does every retired theorem but one a human
  refuted.
- A theorem whose claim the assessor wrote — by a merge, a split, a
  rewrite or an add applied on a review round — carries `minted-by:
  assessor` in the round's records, and the PR's final section
  attributes it to the assessor rather than to the generator or the
  human. A seed claim the human adopted carries no such line.
- `sdlc-agent-result-persist` accepts `--stage assess`, and `--mode
  next` prints an `assess` arm between `generate` and `disprove`. A
  reviewer whose resume passes end in that stage returns `in progress:
  assess — raise it`, as it does for `generate`.
- `/sdlc:orchestrate-analysis` reports each round's assessment as an
  `assessor` phase of its own, and measures the wait for the seed
  ruling from the seed assessor's report rather than the seed
  generator's.
- The review detail posted to a PR carries each round's assessment
  directly after the generator's list.

## 0.85.0 — 2026-11-16

An unconfigured `/sdlc:orchestrate` run now stops for the human less
often, the plan confirm and the batch size are configurable, and
`pr-monitor` no longer leaves a background task running after it
reports.

Changed defaults. To keep an old one, set the key to its old value
with a `sdlc-config-*` verb:

| Key | Old default | New default |
| --- | --- | --- |
| `seed-review` | `ask` | `auto-accept` |
| `merge-poll-interval-seconds` | `120` | `60` |
| `merge-max-unchanged-polls` | `15` | `720` |
| `code-review-max-rounds` | `5` | `10` |
| `loop-end` | `ask` | `auto-when-clean` |
| `docs-loop-end` | `ask` | `auto-when-clean` |

- With no config, the seed theorem list is accepted as generated, and
  a loop whose last review round is APPROVED with no open finding ends
  with no question. A loop at its round cap, or one the human's ruling
  ended, still asks.
- With no config, the monitor loop polls every 60 seconds and asks
  whether to keep waiting after 12 hours without a change in state,
  where it polled every 120 seconds and asked after 30 minutes.
- New config key `plan-confirm`: whether Execution waits for the human
  to confirm the plan. The plan is shown under every value. `ask`
  always waits. `auto` continues without waiting unless the plan
  carries a decision item. `auto-single-batch`, the default, continues
  without waiting only when the plan has exactly one batch and no
  decision item. A plan that does not wait ends with a line saying so
  and naming the value. Before this version every plan waited; set
  `plan-confirm: ask` to keep that.
- New config key `max-issues-per-batch`, a positive integer, default
  `8`: the most issues one batch holds. A batch the grouping would
  make larger is split into more batches. It replaces a fixed limit of
  5 issues per batch, and the plan no longer tells the human to split a
  run of more than 8 issues into two sessions.
- Pre-flight prints both new keys beside the tier each came from, and
  the `sdlc-config-*` verbs offer them.
- The orchestrator no longer asks the human for a `theorem-generator`
  tier. The seed generator runs at the tier the review rubric picks. A
  tier the human names unprompted, at the plan or later, still
  overrides the rubric for that batch.
- `pr-monitor` no longer hands back its report while a background task
  it started is still running. When the harness moves one of its
  polling calls to the background, it waits on that call and acts on
  its result as on a foreground call's. Before it reports, on every
  outcome, it stops every background task and watch it started and
  confirms each has ended, and its report says whether a call was
  moved to the background.

## 0.84.0 — 2026-11-16

`/sdlc:orchestrate` recovers on its own from a branch a dead agent
still holds, and asks for a resolving install at the plan rather than
escalating for one mid-run. Both need `git-tools` 0.12.0.

- An agent whose `git-branch-sync checkout` finds its branch held by
  another worktree reports exit 13. The orchestrator, or
  `pr-merge-readiness` for an agent it spawned, runs `git-branch-sync
  reclaim` on the branch and re-spawns that agent once. It passes
  `--holder-ended` only when the holder is an agent it spawned whose
  call has returned.
- `reclaim` refuses a branch with unfinished work, so this releases
  nothing unsaved. A second exit 13, or a `reclaim` that refuses, goes
  to the human with the output verbatim: a Needs Your Attention row
  from the orchestrator, the question from `pr-merge-readiness`.
- A batch needs a resolving install when a member issue's
  files-affected section lists a lockfile or a package manifest tagged
  `update` or `new`. The plan shows such a batch as a decision item
  with the install command, its directory, and whether any external
  version can move. The batch does not spawn until the human says yes.
- The developer of an approved batch pushes its manifest changes and
  stops, opening no PR. The orchestrator runs the approved command in
  that developer's worktree, commits and pushes the lockfile change,
  and spawns a fresh developer to finish the batch on the same branch.
- An install that fails, or that changes any file but a lockfile, is a
  Needs Your Attention row with its output verbatim.
- A developer continuing on a branch checks it out rather than creating
  one, and reports each member from every commit the branch carries.
- The developer's `Scope:` block is taken from the branch's whole diff
  against the source branch `git-branch-create` reported. On a
  continued branch, where it created none, the developer reads
  `default-issue-source-branch` itself.

## 0.83.0 — 2026-11-15

`/sdlc:orchestrate`'s review loops are now configurable, a Low finding
is fixed like any other, and a documentation round with no theorems can
post its review.

- New config keys `code-review-max-rounds` and
  `docs-review-max-rounds`: the most review rounds the code loop and
  the documentation loop run per PR. Each takes a positive integer or
  `unlimited`, and defaults to `5`, the cap both loops had before.
  Under `unlimited` a loop runs until a review approves with no
  findings.
- New config keys `loop-end` and `docs-loop-end`, each `ask` or
  `auto-when-clean`, default `ask`. `loop-end` governs the code loop's
  end, before the documentation loop starts; `docs-loop-end` governs
  the documentation loop's end, before the merge stages and the ready
  flip. Under `auto-when-clean`, a loop whose last review round is
  APPROVED with no open finding of any severity ends with no question
  and the next stage starts. A loop at its round cap, or one the
  human's ruling ended, still asks. Each key is set on its own, and
  with neither set every loop end waits for the human as before.
- Pre-flight prints all four new keys beside the tier each came from,
  and the `sdlc-config-*` verbs offer them.
- An APPROVED round with an open Low finding now runs a fixer round,
  with no question to the human. A loop ends on a round approved with
  no findings, and a Low still open at a loop's cap is escalated with
  the other open findings.
- The run summary's Low Findings table is gone. A finding still open at
  a cap, a Low included, is a Needs Your Attention row naming the key
  of the loop it persisted in.
- A style-check finding against text the issue body requires is settled
  by the orchestrator, quoting the issue's sentence, and is no longer
  put to the human.
- For a defect the PR's own diff introduced, the orchestrator
  recommends the fix in that PR, never a follow-up issue or leaving it.
- `sdlc-agent-result-persist --mode records` stores an empty payload,
  from `--from` or stdin, as an empty records file. A first
  documentation round whose generator emitted no theorems used to be
  refused there, which stopped the reviewer before it posted. `--mode
  review` and `--mode leave` still refuse an empty payload.

## 0.82.0 — 2026-11-15

The cleanup now keeps review state by default. It used to delete a
merged PR's review state after every `/sdlc:orchestrate` run, and every
PR's on an `--all` sweep, which destroyed what
`/sdlc:orchestrate-analysis` reads and what a round is diagnosed from.

- `/sdlc:orchestrate-cleanup` and `sdlc-orchestrate-cleanup` take a new
  flag, `--review-state`, in both forms. With it, review state is
  deleted as before: the PR's under `<PR>`, every PR's in the
  repository under `--all`. Without it, review state is neither listed
  nor deleted, and no `review-state` line is printed, `--dry-run`
  included.
- `/sdlc:orchestrate`'s post-merge cleanup passes no `--review-state`,
  so a merged PR's review state survives the run until the human
  deletes it.
- The `<PR>` form still removes the worktrees and branches of the
  agents the PR's state names, with or without the flag.
- Under `--all`, the list shown before the go-ahead includes review
  state only when `--review-state` was passed.

## 0.81.0 — 2026-11-13

A review round run after a close-out now reaches the PR, and a piece of
review detail too large for one comment is posted in full rather than
replaced by a pointer at local state the post-merge cleanup deletes.

- A detail chunk's first line is now
  `<!-- sdlc:theorem-records <first>-<last> <i>/<N> -->`, naming the
  lowest and highest round its chain holds. The seed's round-0 records
  ride in a chain without widening its range, unless no round has a
  log, when they post as `0-0`. Chunks in the old `<i>/<N>` form are
  still recognized, so `sdlc-pr-adjustments` keeps leaving them out.
- `sdlc-records-chain` groups chunks by range plus total, so chunks of
  two chains with the same total never combine, and prints one
  `complete\t<first>-<last>\t<N>` line per complete chain, oldest
  first. A complete old-form chain prints `-` as its range, and each
  `partial` line carries the range too.
- Supplementary chains: `sdlc-pr-post-theorem-records` posts one chain
  holding only the rounds above the highest round a complete chain on
  the PR already covers, with a round type's latest records only when
  their round is among them. Nothing already posted is posted again,
  and with no round above the covered one it posts nothing and exits 0.
  A partial chain and an old-form chain cover no round, so the next
  close-out posts a whole chain beside either.
- Its stdout is now one
  `existing chain: rounds <first>-<last>, <N> comments` line per
  complete chain already there that names its rounds, then
  `posted chain: rounds <first>-<last>, <N> comments` and the comment
  URLs when it posted one.
- Oversized-piece splitting: a piece too large for one chunk is split
  across consecutive chunks of its chain, and the "Too large to post"
  placeholder is gone. A split breaks between lines, and only a line
  too long for a chunk is cut, at a UTF-8 character boundary. A code
  fence open at a break is closed in that chunk and reopened in the
  next, and each continuation chunk opens with its file's heading plus
  `(continued)`. A fence a file leaves open is closed at that file's
  end, in a split piece and a whole one alike. A chain needing more
  than 9999 chunks exits 6 and posts nothing.
- `pr-finalizer`'s final section lists each chain with the rounds it
  holds as where the detail is, and never names local state for a
  round's detail.
- Only the human may reopen the review loop after a close-out, at any
  point before merge. The orchestrator returns a PR already marked
  ready to draft with `/github-prs:pr-draft` first, and the next
  close-out posts the rounds the chains are missing and flips it ready
  again.

## 0.80.0 — 2026-11-13

After a context compaction, a conversation gets back the full text of
the skills and rule files it was working from, rather than the
compaction summary's truncated account of them. The plugin now ships a
hook, `reload-after-compact`, that appends that text in one message
once the compaction has run.

- It reloads every skill the compacted loop invoked, through the
  `Skill` tool or as a slash command, and every `.md` file the loop
  opened with `Read` under a `rules/` or `skills/` directory. A plugin
  skill is found in its plugin's installed version, and a skill named
  without a plugin under the project's `.claude/skills/`, then
  `~/.claude/skills/`, then the installed plugins.
- It does not reload a `CLAUDE.md` or a file under `~/.claude/rules/`,
  which the harness re-injects itself, an agent definition, or any file
  opened under an `agents/` directory.
- A subagent's compaction reloads what that subagent invoked and read,
  and the main conversation's reloads its own.
- Once an `/sdlc:orchestrate` run has spawned its first agent, the
  files that serve only its opening — the readiness skill and the
  pre-flight and plan lib files — are no longer reloaded.
- A file used before an earlier compaction is reloaded again at a later
  one. The hook carries each loop's uses in a state file under
  `${XDG_STATE_HOME:-$HOME/.local/state}/sdlc/reload-after-compact/`,
  keyed by session and loop, rather than reading them back from an
  earlier reload message. Earlier reload messages are removed, so the
  conversation holds at most one.
- A new config key, `reload-after-compact-token-budget`, caps the
  reload, with tokens counted as characters ÷ 4. It defaults to
  `100000` and takes an integer of at least `64000`, written as one
  `reload-after-compact-token-budget: <digits>` line starting in the
  first column. Files are appended most recently used first, and the
  ones past the budget are listed by absolute path with an instruction
  to read each before acting on it.
- When a config tier file cannot be read, fails its `schema-version`
  check or holds an invalid budget line, the hook reloads nothing and
  writes one log line to the human naming the path and the error. It
  never falls back to the default for a broken tier. Any other line
  containing the key's name, a commented-out one or a second budget
  line included, makes the tier invalid.
- A file that cannot be read is named in the reload message with its
  error, and the compaction still completes.

## 0.79.0 — 2026-11-12

A review the pipeline did not post — a code-scanning review, a human
review — no longer shifts a PR's round numbers or moves the adjustments
cut, and a round number with no log no longer hides the rounds above it.

- The review body `sdlc-agent-result-persist --mode summary` renders
  opens with a stamp, `<!-- sdlc:review-round <n> -->`, naming its
  round. A review carrying the stamp on any line is a pipeline review;
  so is an unstamped one with both a `## Verdicts` and a
  `## Review method` line, as reviews posted before this version are.
  No other review is one.
- `sdlc-pr-round` numbers the round under way from the PR's pipeline
  reviews and its rounds' state rather than from its review count: the
  round after the highest stamped one, or, with no stamp, after the
  round holding the newest posted review's file. A round above that
  already begun and not yet posted keeps its number. A failed state
  read exits 1.
- `sdlc-agent-result-persist --mode rounds` lists each round from 1
  that has a log, ascending, leaving out the seed round and voided
  rounds.
- The review detail `pr-finalizer` posts, and the rounds its final
  section reports, cover every round that mode lists. Both used to
  count up from round 1 and stop at the first number with no log, which
  dropped every round on a PR whose first round was numbered 2.
- `sdlc-pr-adjustments` cuts at the newest pipeline review, so a comment
  posted before a code-scanning or human review still reaches the next
  round as an adjustment.

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
