# github-prs

GitHub-only skills for the operations a pull request goes through:
create it (as a draft, closing its own issue set), fetch its diff,
submit a review with a verdict, flip it between draft and
ready-for-review, report whether it can be merged and enumerate the
conflicts when it cannot, link it to the issues it resolves via one
closing keyword each in the PR body, and read those closing lines back
to say which issues it closes.

These skills serve the `/sdlc:orchestrate` flow and its agents. The
`issue-developer` opens the PR. The
`theorem-based-pr-reviewer` posts the single review that carries the
verdict, and — when run standalone on a bare PR number — reads the
PR's closing lines to learn which issues it claims; the
agents it spawns — every `theorem-generator` variant,
`theorem-disprover`, and `counterexample-verifier` — fetch the diff, as do the `issue-fixer`,
`code-documenter`, `style-checker`, and `docs-writer`. The orchestrator
keeps PRs draft through the review/fix loop; once the human blesses a
PR at end-of-loop it gates the close-out on the PR's merge readiness,
enumerating the conflicts when the branch has any, and only then reads
those same closing lines for the issues it flips to In Review and
flips the PR draft → ready. It keeps reading the merge readiness while
it waits for the merge. Each skill is still a standalone verb usable
by a human or any caller.

## One PR, one issue set

A PR in this flow delivers a **batch**: an ordered set of one or more
issues implemented on one branch. A batch of one is the ordinary
single-issue PR, so nothing below is extra work for that case.

`git-tools:git-branch-create` encodes the set in the branch name, and
`git-tools:git-issues-from-branch` — its inverse — recovers it. That
skill is also where the **issue-to-branch reconciliation rule** is
applied, and neither skill here restates it. `/pr-create` and
`/pr-link-issue` each hand `git-issues-from-branch` the branch plus
their own claim — the numbers
their caller passed, which a caller of either always has in hand — and
act on the outcome it reports. Neither parses a branch name and
neither re-derives the resolution.

That cross-plugin invocation is why this plugin's `plugin.json`
declares a `dependencies` edge on `git-tools`: the edge guarantees the
skill is installed and enabled wherever these skills run. It grants
no access to `git-tools`' files.

What differs between the two is only the **action** each takes on what
the skill reports. Where there is no safe resolution, `/pr-create`
opens no PR and `/pr-link-issue` leaves the PR body untouched. On a
branch member the skill reports as *not claimed*, `/pr-create` names
the deferred issue and why in the body it is writing, while
`/pr-link-issue` — which only appends closing lines to a body someone
else authored — leaves that judgement to the reviewer. Both report the
outcome with both sets, and both name any passed number the skill
placed outside the branch's set — those never get a closing line.

Each member needs **its own closing keyword** — GitHub links only a
reference that carries a keyword immediately before it, so
`Closes #196, #201` links `#196` and silently leaves `#201` unlinked.
Both skills therefore write one `Closes #<issue>` line per issue.

Reading those lines back belongs to `/pr-closing-issues` alone: it is
the one skill in this marketplace that parses a PR body's closing
lines, so every skill and agent that acts on which issues a body
closes invokes it instead of scanning the body itself. `/pr-create` is
not a consumer — it writes closing lines and never reads them.

## Readiness is reported, never remedied

`/pr-ready-to-merge` and `/pr-merge-conflicts` are the two skills that
answer whether a PR can move forward, and both are read-only by design.
"Ready for review" is a draft flag and says nothing about whether the
branch is current with its base, merges cleanly, or passes its required
checks; `mergeStateStatus` does, and GitHub reports `DIRTY` without
saying which files or hunks conflict, so the second skill trial-merges
the base in a throwaway worktree under `.claude/worktrees/` to find
out, then aborts the merge and removes the worktree. Neither rebases,
resolves, pushes, or flips anything: a caller that acts on a `BEHIND`
or a `DIRTY` owns the remedy and whoever performs it, and this plugin
carries no rule about what a given state should trigger. Keeping the
readiness read separate from the remedy is what lets a human check a
PR by hand with the same verb an orchestrator gates on.

`/pr-ready-to-merge` refuses a PR that is not open rather than
retrying: GitHub stops computing merge state once a PR closes, so a
merged or closed PR reports `UNKNOWN` permanently, and a retry
schedule run against one would exhaust itself and then report a
readiness failure that means nothing.

Every skill is GitHub-only **by design**: each is built directly on the
`gh` CLI, and there is no CodeCommit (or other source-control) branch
in any of them. CodeCommit is deliberately out of scope here, not
deferred.

## Config: read internally, not by the caller

Every skill but `pr-create` takes everything it needs as arguments
and reads no configuration at all. Only `pr-create` reads repo-config —
`default-pr-target-branch` and `issue-link-prefix` — and it does so
**internally**, via a lightweight inline parse of just those two
front-matter lines, not the `issues` plugin's full
`skills/lib/repo-config.md` reader contract (that lib lives inside the
`issues` plugin and isn't reachable across the plugin sandbox
boundary). Neither `pr-create` nor `pr-link-issue`
reads anything about the **branch name**: both invoke
`git-tools:git-issues-from-branch`, which reads
`issue-branch-naming-prefix` internally in turn.

The caller just invokes the skill with the issue/PR number — the
operation owns its own config read where it needs one. This is the
whole point of the split: a caller no longer parses repo-config to
hand-roll a raw `gh pr create`/`gh pr diff`/`gh pr review`.

## Skills

| Skill | Purpose | Underlying command |
| ------- | --------- | -------------------- |
| `/pr-create <issue>… <branch>` | Open a draft PR for a branch against the right base, closing its own issue set | `gh pr create --draft --base <target>` |
| `/pr-diff <PR>` | Fetch a PR's full diff | `gh pr diff <PR>` |
| `/pr-review-submit <PR> --verdict <verdict> <body>` or `--body-file <path>` | Post a single PR review carrying a verdict, with the body inline or from a file | `gh pr review <PR>` |
| `/pr-ready <N>` | Mark a draft PR ready for review (draft → ready) | `gh pr ready <N>` |
| `/pr-draft <N>` | Convert a ready PR back to a draft (ready → draft) | `gh pr ready <N> --undo` |
| `/pr-ready-to-merge <PR>` | Report an open PR's merge readiness — `mergeable`, `mergeStateStatus`, review decision and check rollup — retrying while GitHub is still computing it | `gh pr view <PR> --json mergeable,mergeStateStatus,…` |
| `/pr-merge-conflicts <PR>` | Enumerate a PR's actual merge conflicts with its base — files and hunks — by a trial merge that is aborted afterwards | `git merge --no-commit --no-ff` in a throwaway worktree |
| `/pr-link-issue <PR> <issue>…` | Ensure the PR body links & closes every issue in its own set | verify/append the missing `Closes #<issue>` lines in the PR body |
| `/pr-closing-issues <PR>` | Report which issues the PR body closes | `gh pr view <PR> --json number,body` |

### `/pr-create <issue>… <branch>`

Opens a pull request for `<branch>` as a **draft**, against the base
branch read from `default-pr-target-branch` in repo-config, with one
`Closes <link-prefix><issue>` line per issue in the PR body so the PR
links and auto-closes each of them on merge. Reads
`default-pr-target-branch` and `issue-link-prefix` internally via a
lightweight inline parse (see "Config: read internally, not by the
caller" above). Every `<issue>` must be a member of the branch's own
set (see "One PR, one issue set" above); a caller-supplied number
outside it never gets a closing line, and the refusal is named in the
report-back; a branch member the caller did not claim is named in the
body as a deferral, so a reviewer can tell one from a silent
under-delivery. On the no-safe-resolution outcome the skill opens no
PR at all. See the skill for the closing-keyword rule (PR body only,
own issue set only, never a commit).

### `/pr-diff <PR>`

Fetches the full unified diff of a pull request via `gh pr diff <PR>`.
This is the diff-fetch that every `theorem-generator` variant,
`theorem-disprover`, `counterexample-verifier`, `issue-fixer`, `code-documenter`,
`style-checker`, and `docs-writer` need
before they read a PR's changes.

### `/pr-review-submit <PR> --verdict <verdict> <body>` / `--body-file <path>`

Posts a **single** pull-request review carrying both a verdict and a
body in one call. The verdict is `approve`, `request_changes`, or
`comment` — GitHub's own review actions — and the body opens
with the matching verdict word on every post. Because GitHub refuses
both verdict flags from a PR's own author, leaving an author only a
comment, the skill posts those two via `--comment` in that self-review
case rather than failing, and reports the review state it actually
created.

The body arrives in exactly one form — inline as the last argument, or
as `--body-file <path>` naming a file that holds it — and either works
with every verdict.
`sdlc:theorem-based-pr-reviewer` uses the file form — it stages the
review summary under `.claude/tmp/<task-slug>/` and posts it by path,
because that summary carries a backticked state-relative detail path on
every theorem and finding line, under the
`${XDG_STATE_HOME:-$HOME/.local/state}` root it names once, and the
inline form hands every backtick and `$` in it to the shell. In the
file form the skill composes a **new** file carrying the verdict line
ahead of the caller's text, leaving the caller's own file untouched.

### `/pr-ready <N>`

Flips a draft PR into ready-for-review. A draft PR cannot be
auto-merged (the repo's auto-merge workflow filters `isDraft ==
false`), so keeping PRs draft until this point is what enforces "the
orchestrator never merges." Safe to run more than once — `gh` no-ops
if the PR is already ready.

### `/pr-draft <N>`

Converts a ready PR back to a draft, re-arming that safety gate. Used
manually when a PR that looked ready turns out to still need work.
Safe to run more than once.

### `/pr-ready-to-merge <PR>`

Reads `mergeable` and `mergeStateStatus` off an open PR, with
`reviewDecision` and `statusCheckRollup` alongside so a caller can tell
what a `BLOCKED` is blocked on — a missing required review, a failing
required check and a required check still running all report the same
word — and reports them with GitHub's meaning of the state. Refuses a
PR that is not open as an input error (see "Readiness is reported,
never remedied" above). `mergeable: UNKNOWN` on an open PR means the
merge commit is still being computed, so the skill retries on a fixed,
announced schedule and fails reporting `UNKNOWN` if it never resolves;
the schedule is a declared starting bound the skill states as such.
What a caller does about each state is the caller's own rule.

### `/pr-merge-conflicts <PR>`

Adds a detached throwaway worktree at the PR's head, trial-merges the
base there without committing, collects the conflicting files and
each one's conflicting hunks, then aborts the merge and removes the
worktree — whatever the collection steps produced, so a failed run
leaves nothing for the next one to trip on. The primary clone's
`git status` reads the same before and after. It reports the
conflicts and nothing else; what to do about each is the caller's to
decide.

### `/pr-link-issue <PR> <issue>…`

Set-idempotent verify/append. Asks `/pr-closing-issues` what the body
already closes; members already covered are left alone, the missing
ones get a `Closes #<issue>` line appended, and a body that already
covers every member is a no-op. A closing keyword in the PR body is
GitHub's sanctioned mechanism for both the Development-sidebar "linked
pull request" **and** the auto-close-on-merge to the default branch.

Every `<issue>` must be a member of the branch's **own** set — never
an umbrella/parent/related issue. The passed numbers are the claim the
skill hands to `git-tools:git-issues-from-branch` alongside the head
branch (see "One PR, one issue set" above); on the no-safe-resolution
outcome it leaves the body untouched. Passing a subset is how a
deliberately deferred member stays un-closed.

### `/pr-closing-issues <PR>`

Fetches the PR body and reports the set of issues it closes, applying
the closing-keyword-immediately-before-reference syntax. It is
the one place in this marketplace that syntax is applied to a PR body,
so every skill and agent that acts on which issues a body closes — for
an idempotency check, a standalone review's claim, a status flip, or a
before-and-after comparison around a body edit — invokes it rather
than scanning a body itself. A single-PR primitive: a caller holding
several PRs loops.
