# Issue Lifecycle

The issue-status transitions the orchestrator makes, the gate every one
of them passes through, and how the `/issue-*` namespace is used for
them.

## The transitions

Each issue's board status tracks its lifecycle via `/issue-set-status`:
In Progress before its batch's developer spawns, In Review in the
close-out — after the merge-readiness loop has passed, not on the
documentation loop's end that starts it, and after `pr-finalizer`'s
amendment of the PR body — for every member the PR then closes. The
assign that accompanies the first is outside this file's gate: it is
not a status, it happens once, and nothing later unassigns — a member
dropped from a batch mid-run keeps its assignee.

### In Progress, and assign, before the batch's developer spawns

Immediately after the plan is settled — the human confirmed it, or
`plan-confirm` let it through without waiting — and **before spawning
the developer for a given batch**, transition every member of that
batch to In Progress and assign it — they start together because one
developer starts them together:

```text
/issue-set-status <N> "In Progress"
/issue-update <N> --add-assignees @default-assignee
```

once per member, as the batch's wave is about to be spawned — a batch
queued behind another wave flips only when its own developer is about
to start.

The status flip is gated as below. The assign is not: a repo with no
status slot skips the flip and still assigns, because an issue someone
is driving should say so whatever the board offers.
`@default-assignee` is a literal token `/issue-update` resolves, and
the call is additive, so no assignee already on the issue is displaced.

### In Review, in the close-out

At the close-out's flip step, after `pr-finalizer` has amended the PR
body, once per member of the set `/github-prs:pr-closing-issues` then
reports:

```text
/issue-set-status <N> "In Review"
```

They flip together, because they ship together.

## The status-slot gate

Both transitions are **gated on a configured status slot**: the repo
must have `github-project.fields.status` (GitHub) or the Jira `status`
slot in `.issues/repo-config.md`. If no status slot is configured,
**warn-and-skip** — emit a one-line note that status tracking is not
configured and continue the run. Do **not** abort.

**Option-name fallback.** `/issue-set-status` matches option names
case-insensitively, so `"In Progress"` / `"In Review"` resolve to a
board's `In progress` / `In review` options automatically. But if the
board has a status slot that **lacks** a matching option — i.e.
`/issue-set-status` aborts with its "Slot value not in options map"
error — catch that abort and put it to the human as a decision, as the
skill's "Putting a decision to the human" says: one option for each of
the board's status options, at most three, that could stand in for it,
and one that skips the transition for this run. Never let that abort
fail the whole run.

## The `/issue-*` namespace

Wherever a `/issue-*` skill exists for an operation, use it rather
than the raw `gh issue …` or `gh api graphql` call: the skills read
repo-config, respect the board, and dispatch on the tracker, and a raw
call silently does the GitHub-only thing. Where no skill exists — a
bulk `gh issue list` filter, a field the namespace does not expose,
the read-only `git` planning commands — raw `gh` and `git` stay the
tool. A PR call goes through the `/github-prs:*` skill that has a verb
for it, on the same terms.

A follow-up issue the human asks for is filed via `/issue-create`, and
the human is asked first when the body would be long-form and
multi-step. Each field the order named no value for is filed as its
`follow-up-issue-*` key calls for, per `skills/lib/sdlc-config.md`. Raw
`gh issue create` is not a substitute: it files an unconfigured issue.
After `/issue-create` returns, read the issue back
with `/issue-view <new-N>` and confirm the type, the configured slot
fields and the assignee are populated as repo-config requires; report
a gap in the same reply rather than declaring the issue filed.
