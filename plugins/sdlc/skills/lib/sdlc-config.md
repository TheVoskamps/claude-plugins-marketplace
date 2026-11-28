# sdlc config contract (`skills/lib/sdlc-config.md`)

This file is the single statement of **where** sdlc's config files
live, **what** they hold, **how** the three of them resolve into one
value per key, and **how** a writer updates one. It is reference prose,
not an executable script.

No agent reads these files. `/sdlc:orchestrate` and
`/sdlc:orchestrate-ready` each resolve them once per run, and a value a
teammate needs travels in that teammate's brief.
The one exception is the `reload-after-compact` hook, which resolves
`reload-after-compact-token-budget` itself on every compaction, per
"Reading", because it runs outside any orchestrate run and has no brief
to receive a value. It checks only a file's read, its `schema-version`
and that key's budget lines, as the key's description defines them,
reading `schema-version` off its own top-level line. It parses no YAML,
so YAML malformed elsewhere in the file goes unchecked. Where "Reading"
aborts on one of those checks the hook reloads nothing: it appends no
reload message, the compaction completes on the summary alone, and it
writes one `$.ui.log` line to the human naming the path and the error.
It never falls back to the key's default for such a tier, and never
names a config error in text sent to the model.

## The tiers

| Tier | Path | Tracked |
| --- | --- | --- |
| 1. Global user | `${XDG_CONFIG_HOME:-$HOME/.config}/sdlc/user-config.yml` | no |
| 2. Shared repo | `<repo-root>/.sdlc/repo-config.yml` | yes |
| 3. Repo user | `<repo-root>/.sdlc/user-config.yml` | no (gitignored) |

`$XDG_CONFIG_HOME` is used when it is set and non-empty, `$HOME/.config`
when it is unset or empty. Resolve it by reading the environment
(`printenv XDG_CONFIG_HOME`, `printenv HOME`) and use the absolute path.
`<repo-root>` is what `git rev-parse --show-toplevel` prints.

Every key may be set at every tier. When a key is set in more than one
file, the highest-numbered tier wins; a key set in none takes its
default.

## The shape

Plain YAML, one document, no front-matter fences. `schema-version` is
the first key; every key is kebab-case.

```yaml
schema-version: 1
seed-review: ask
merge-poll-interval-seconds: 300
```

## The keys

| Key | Values | Default |
| --- | --- | --- |
| `plan-confirm` | `ask` \| `auto` \| `auto-single-batch` | `auto-single-batch` |
| `max-issues-per-batch` | positive integer | `8` |
| `seed-review` | `ask` \| `accept-as-emitted` \| `accept-recommended` | `accept-recommended` |
| `merge-wait` | `monitor` \| `skip` | `monitor` |
| `merge-poll-interval-seconds` | positive integer | `60` |
| `merge-max-unchanged-polls` | positive integer | `720` |
| `merge-poll-error-retry-seconds` | positive integer | `30` |
| `merge-poll-error-max-retries` | positive integer | `15` |
| `reload-after-compact-token-budget` | decimal integer, at least `64000` | `100000` |
| `code-review-max-rounds` | positive integer \| `unlimited` | `10` |
| `docs-review-max-rounds` | positive integer \| `unlimited` | `5` |
| `loop-end` | `ask` \| `auto-when-clean` | `auto-when-clean` |
| `docs-loop-end` | `ask` \| `auto-when-clean` | `auto-when-clean` |
| `ready-rewrite-approval` | `ask` \| `auto` | `ask` |
| `orchestrate-statuses` | a list of one or more status names | `[Todo, Ready]` |
| `orchestrate-ready-statuses` | a list of one or more status names | `[Backlog, Todo, Ready]` |
| `follow-up-issue-type` | `repo-default` \| `ask` \| a type name | `repo-default` |
| `follow-up-issue-priority` | `repo-default` \| `ask` \| an option name | `repo-default` |
| `follow-up-issue-status` | `repo-default` \| `ask` \| an option name | `repo-default` |
| `follow-up-issue-assignee` | `repo-default` \| `ask` \| `@me` \| `none` \| a login | `repo-default` |
| `outside-criteria-finding` | `ask` \| `fix-in-pr` | `fix-in-pr` |
| `recurring-finding-class` | `ask` \| `fix-class` | `fix-class` |

- **`plan-confirm`** — whether the orchestrator waits for the human's
  confirmation of the plan before Execution. The plan is presented
  under every value. `ask` always waits. `auto` continues to Execution
  without waiting unless the plan's `Decision items` line is not
  `none`. `auto-single-batch` continues without waiting when the plan
  has exactly one batch and its `Decision items` line is `none`, and
  waits otherwise.
- **`max-issues-per-batch`** — the most issues one batch holds. A batch
  the grouping would make larger is split into more batches.
- **`seed-review`** — `ask` stops for the human's ruling on the seed
  theorem list. `accept-as-emitted` accepts every seed theorem as the
  generator emitted it, applies none of `theorem-assessor`'s
  recommendations, and does not wait. `accept-recommended` applies
  every recommendation, coverage-gap adds included, and does not wait.
  `auto-accept` is a deprecated alias: a tier that sets it holds
  `accept-as-emitted`.
- **`merge-wait`** — `monitor` spawns `pr-monitor` after a PR's ready
  flip. `skip` spawns none; the PR is left ready and unmonitored.
- **`merge-poll-interval-seconds`** — the wait between two
  `pr-monitor` polls, with no upper cap.
- **`merge-max-unchanged-polls`** — how many consecutive polls with no
  change in state `pr-monitor` runs before it asks whether to keep
  waiting.
- **`merge-poll-error-retry-seconds`** — the wait before `pr-monitor`
  tries a poll again after it failed on a recoverable error, such as a
  dropped connection, with no upper cap.
- **`merge-poll-error-max-retries`** — how many consecutive recoverable
  poll failures `pr-monitor` retries; the next one ends its loop as a
  script error. A completed poll restarts the count. No upper cap.
- **`reload-after-compact-token-budget`** — how many tokens, counted
  as characters ÷ 4, of skill and rule-file text the
  `reload-after-compact` hook appends to a compacted conversation.
  The files past it are listed by path, to be read before acting on
  them. The table's floor holds an orchestrate run's own skill, lib
  and interface files past its opening: these files under
  `plugins/sdlc/skills/`, about 52k tokens as the hook counts them:
  `orchestrate/SKILL.md`, `orchestrate/lib/issue-lifecycle.md`,
  `orchestrate/lib/pr-lifecycle.md`, `orchestrate/lib/wrap-up.md`,
  `orchestrate-readiness/SKILL.md`,
  `agent-result-persist-interface/SKILL.md`,
  `theorem-agents-interface/SKILL.md`, `lib/decision-record.md` and
  `lib/sdlc-config.md`. Any other skill the run invokes, and the files
  its own work reads, are not counted; the floor's headroom above
  those files covers them. Any line of a tier file that contains
  `reload-after-compact-token-budget` is a budget line, a comment or
  another key's value included. A budget line is valid only when it
  matches `^reload-after-compact-token-budget: [0-9]+$` and its number
  is not below that floor. Every other budget line, a second one
  included, is outside its allowed values.
- **`code-review-max-rounds`** — the most review rounds the code loop
  runs per PR. `unlimited` runs the loop until a review approves with
  no findings.
  `unlimited` is the one string allowed beside a positive integer; any
  other string is outside the allowed values, as `0`, a negative and a
  float are.
- **`docs-review-max-rounds`** — the most review rounds the
  documentation loop runs per PR; no code-loop round counts against it.
  Its values are `code-review-max-rounds`'s, applied to the
  documentation loop.
- **`loop-end`** — governs the code loop's end, before the
  documentation loop starts, and has no effect on the documentation
  loop's. `ask` waits for the human's confirmation, per PR, that the
  loop is done and the PR is good enough to move forward.
  `auto-when-clean` ends a clean loop with no question and starts the
  next stage, because under that value the human confirmed every clean
  end of the loop in advance. A loop's end is **clean** when its last
  review round is APPROVED with no open finding of any severity. Every
  other end still asks, under either value: a round at the loop's cap,
  and a round the human's ruling ended.
- **`docs-loop-end`** — governs the documentation loop's end, before
  the merge stages and the ready flip, and has no effect on the code
  loop's. Its values, and what a clean end is, are `loop-end`'s,
  applied to the documentation loop.
- **`ready-rewrite-approval`** — whether `/sdlc:orchestrate-ready` asks
  the human to approve the acceptance criteria and the files-affected
  list before it rewrites an issue's body. `ask` asks that closing
  question. `auto` rewrites the body without it once every design gap
  has the human's stored answer, and prints the criteria and the file
  list it wrote.
- **`orchestrate-statuses`**, **`orchestrate-ready-statuses`** — the
  statuses an issue may be at for `/sdlc:orchestrate` and for
  `/sdlc:orchestrate-ready` respectively to run on it. Each skill passes
  every name its key resolves to, its default included, as an
  `--allow-status` of every readiness check it runs. A name is matched
  against the issue's status case-insensitively and literally, so a
  name the board lacks matches nothing and is no error. A higher tier's
  list replaces a lower one's, never merges with it.
- **`follow-up-issue-type`**, **`follow-up-issue-priority`**,
  **`follow-up-issue-status`**, **`follow-up-issue-assignee`** — the
  fields a follow-up issue the human ordered is filed with, through
  `/issue-create`, for each field the order named no value for. A field
  the human named takes the human's value whatever its key holds.
  - `repo-default` passes the target repository's own default
    explicitly, so nothing is asked. For priority and status that is
    the `(default: …)` `/issue-field-options [<repo>] <slot>` reports,
    passed as `--priority` or `--status`. A slot the target configures
    with no default falls back to `ask` for that field, and the skill
    filing the issue says so beside the prompt; a slot reporting itself
    unconfigured gets no flag and no question. For the type and the
    assignee it is the default `/issue-create` itself resolves — the
    target's `issue-types:` default and its `default-assignee` — so the
    flag is left off. A higher tier sets `repo-default` to cancel a
    value a lower tier set.
  - `ask` leaves the field to `/issue-create`'s own prompt: no flag is
    passed. For the type and the assignee, which `/issue-create` does
    not prompt for, the field is a question of its own before the issue
    is filed.
  - A type or option name is passed as `--type`, `--priority` or
    `--status`; a login as `--assignee`. `@me` passes the authenticated
    GitHub user's login, as `gh api user --jq .login` prints it. A file
    sets it quoted, `follow-up-issue-assignee: '@me'`: YAML reserves `@`
    at the start of a plain scalar, so a bare `@me` is malformed YAML,
    which "Reading" aborts on. `none` passes `/issue-create`'s
    unassigned value, `--no-assignee`. Any non-empty string is allowed
    at read time; `/issue-create` refuses a name or login the target
    does not accept, before it files anything.

  The size has no key: a configured size slot gets `--size` with the
  option `/issue-create`'s size evaluation heuristic picks from the
  issue's body.

### Standing rulings

A **standing ruling** is a key named after a class of the decision
record — a class `sdlc-decision` defines — whose values are `ask` and
one or more named rulings. Its default is `ask` unless its row in the
table above names a ruling. A skill passes each such key whose resolved
value is not `ask` to each `sdlc-decision ask` call its own conditions
admit, as `--ruling <class>=<value>`, and a record of that class is
then resolved by the key: no question is asked, and the skill applies
the ruling the key's description defines. `ask` puts every record of
the class to the human, and so does a key the skill's own text names no
conditions for: the skill passes no `--ruling` for it.

- **`outside-criteria-finding`** — a finding, or an observation no
  review filed, whose fix lies outside the issue's acceptance criteria.
  `fix-in-pr` fixes the defect in this PR, with the issue edit the fix
  needs.
- **`recurring-finding-class`** — a class of finding filed on two
  consecutive rounds. `fix-class` makes the next fixer brief cover every
  instance of the class rather than the reported ones.

## Reading

The pin is **`schema-version: 1`**. Read tier 1, then tier 2, then
tier 3, each with the `Read` tool, and handle every file by the first
of these that applies:

- **The read ran and reported that the file does not exist** — the
  tier contributes no keys.
- **The read did not run, or failed for any other reason**, whatever
  refused it — abort, naming the path and quoting the error. A refused
  read says nothing about whether the file exists, so it is never
  treated as a missing one.
- **The YAML is malformed, or `schema-version` is absent** — abort,
  naming the path.
- **`schema-version` is lower than the pin** — abort, naming the path
  and both versions.
- **A key from the table above holds a value outside its allowed
  values** — abort, naming the path and the key. A positive integer is
  a YAML integer of 1 or more; `0`, a negative, a float and a quoted
  string are all outside it, and so is an integer above the key's
  stated maximum. A list-valued key holds a YAML sequence of one or
  more non-empty strings; a scalar, an empty sequence, and a sequence
  holding anything but a non-empty string are all outside it. A key
  whose description states a narrower shape
  takes only that shape. A deprecated alias a key's description names
  is read as the value it stands for before this check, so it is never
  outside the allowed values.
- **Otherwise** — the tier contributes every key from the table above
  that it sets. A key the table does not list is ignored, and so is a
  `schema-version` above the pin.

Validate every file before resolving any key, so a bad value at a tier
that a higher tier overrides still aborts. Then resolve each key per
"The tiers", recording the tier its value came from — `global user`,
`shared repo`, `repo user`, or `default`.

## Writing

Each writer owns one tier's file and runs these steps against it.

1. **Resolve the lower tiers.** Read every tier below the writer's own
   per "Reading", with the same aborts, and resolve each key over those
   tiers and the defaults alone. Tier 1 has no lower tier, so its
   writer resolves to the defaults.
2. **Read the writer's own file.** Absent, it will be created. Present,
   read it with the same aborts as "Reading", except that a
   `schema-version` below the pin is re-stamped to the pin rather than
   aborted on. Keep every key in it, the ones the table does not list
   included.
3. **Ask, one key at a time**, in table order. Before each question,
   show the value the lower tiers resolve to and the tier it comes
   from, and the value the writer's own file sets now, if any. Offer
   every allowed value and **leave unchanged**. A positive-integer key
   takes a typed value, re-asked until it is within the key's allowed
   values; `code-review-max-rounds` and `docs-review-max-rounds` offer
   `unlimited` beside it. A key that takes a name or a login offers its
   fixed values and takes a typed name beside them. A list-valued key
   offers the board's status options, as `/issue-field-options status`
   reports them, and takes typed names beside them; its answer is one
   or more names, and an answer of none is re-asked. When that skill
   exits non-zero, as it does outside a git working tree, or reports
   the slot unconfigured, the key offers no options, says why beside
   the question, and takes typed names alone: its stop ends that
   skill's call, never the writer's run.
4. **Merge.** Replace only the keys answered with a value this run.
   A key left unchanged keeps its current value, or stays absent if it
   was absent — the writer never writes a key the user left unset, and
   never deletes one. A key the file sets to a deprecated alias is
   written as the value the alias stands for, answered or left
   unchanged, so no writer writes an alias. A value YAML cannot hold as
   a plain scalar, such as `@me`, is written single-quoted, and so is
   each name of a list-valued key that a flow sequence cannot hold
   plain, such as one carrying a comma. A list-valued key is written as
   a flow sequence, `orchestrate-statuses: [Todo, Ready]`,
   in the order the names were given. Set
   `schema-version: 1` as the first key; keep every other key in its
   existing order and append new keys after them.
5. **Show the merged file and wait for a yes** that names the write.
   Then write it whole with the `Write` tool, which creates a missing
   parent directory.
6. **Report** the path written, the keys changed, and the keys kept.

A writer commits nothing and pushes nothing. A tracked file it writes
is the user's to commit.
