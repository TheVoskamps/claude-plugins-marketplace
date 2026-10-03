# github-prs

GitHub-only skills for the operations a pull request goes through:
create it (as a draft, closing its own issue set), read it, fetch its
diff, list the PRs a branch has opened, submit a review with a verdict,
comment on it, replace its body, flip it between draft and
ready-for-review, report whether it can be merged and enumerate the
conflicts when it cannot, link it to the issues it resolves via one
closing keyword each in the PR body, and read those closing lines back
to say which issues it closes. Every verb is a bundled script the skill
runs, so no model assembles a `gh pr` call by hand (see "Every verb is
a script" below).

These skills serve the `/sdlc:orchestrate` flow and its agents. The
`issue-developer` opens the PR. The
`theorem-based-pr-reviewer` posts the single review that carries the
verdict, and — when run standalone on a bare PR number — reads the
PR's closing lines to learn which issues it claims; the
agents it spawns — every `theorem-generator` variant,
`theorem-disprover`, and `counterexample-verifier` — fetch the diff, as do the `issue-fixer`,
`code-documenter`, `style-checker`, and `docs-writer`. The orchestrator
keeps PRs draft through the review/fix loop; once the human blesses a
PR at end-of-loop, `pr-merge-readiness` gates the close-out on the PR's
merge readiness, enumerating the conflicts when the branch has any and
reading the closing lines for the issue set it briefs `docs-writer`
with after a remedy, and only then does the orchestrator read those
same closing lines for the issues it flips to In Review and flip the
PR draft → ready.
`pr-monitor` keeps reading the merge readiness while the PR waits for
its merge. Each skill is still a standalone verb usable by a human or
any caller.

## Every verb is a script

Each skill runs an executable of the same name under `bin/`, on the
agent's `PATH` once the plugin is enabled, and the SKILL.md says only
when to call the verb, how to invoke the script, and what its output
and exit status mean. No SKILL.md carries an inline `gh` procedure.
The point is ownership: a model that assembles a `gh pr` call from a
prose recipe assembles it slightly differently each time, so the
call's shape, the check that it did what it says, and the wording of
its failures had no single owner. Now the script owns all three, and a
caller elsewhere in the marketplace goes through the skill rather than
spelling a `gh pr` call of its own — which is also what would let a
permission gate refuse raw `gh pr` use later without breaking a caller.

The scripts share one sourced helper, `bin/lib/github-prs-common.sh`,
which holds the error catalogue and the `gh` call wrapper. A script
reports a failure by calling a catalogue entry and never spells a
message of its own, so an exit status means the same thing whichever
verb returned it:

| Exit | Meaning |
| --- | --- |
| 0 | the verb did what it says |
| 1 | the verb's own negative outcome: a change that did not land on the re-read, a PR that is not open, a merge state still `UNKNOWN` |
| 2 | a usage error; nothing was sent to GitHub |
| 3 | a `gh` call — or, for `pr-merge-conflicts`, a `git` step — failed, with the tool's own stderr passed through above the catalogue line |
| 4 | `.issues/repo-config.md` is missing or lacks a key the verb reads |

A verb that changes a PR **re-reads it afterwards** and exits 1 when
the change is not there — `pr-create` checks the draft flag, base, head
and body it asked for; `pr-ready` and `pr-draft` check `isDraft`;
`pr-update` and `pr-link-issue` check the body; `pr-comment` re-reads
the comment by the id GitHub gave it; `pr-review-submit` checks that a
new review exists with the state and body it posted. The re-read lives
in the script, so a skill never has to tell its caller to verify. The
read-only verbs re-read nothing.

A body reaches `gh` by file path or on stdin (`--body-file -`), never
as a command-line argument: a review summary or a PR body full of
backticks and `$` would otherwise be read by the shell first. That is
why every body-taking verb accepts `--body-file <path>`, and why
`pr-review-submit` composes the posted body in memory rather than
writing a scratch copy beside the caller's file.

Every script runs under the bash 3.2 that macOS ships. The suite at
`test/github-prs-test.sh` runs each script against a stub `gh` that
keeps a PR's state in files and applies `--jq` filters with the real
`jq`, checking the call shape each script issues, the re-read after
each mutation — including a mode in which the mutation does not land,
so every exit-1 path is exercised — and the error wording; no test
posts anything to GitHub.

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
`default-pr-target-branch` and `issue-link-prefix` — and its script
does so **internally**, via a lightweight inline parse of just those
two front-matter lines, not the `issues` plugin's full
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

Each row's script is `bin/<verb>`; the last column is the `gh` call
that script makes.

| Skill | Purpose | Underlying command |
| ------- | --------- | -------------------- |
| `/pr-create <issue>… <branch>` | Open a draft PR for a branch against the right base, closing its own issue set | `gh pr create --draft --base <target>` |
| `/pr-view <PR> [--json <fields> [--jq <expr>]]` | Print a PR — a fixed dump, or the named fields | `gh pr view <PR> [--json …]` |
| `/pr-diff <PR>` | Fetch a PR's full diff | `gh pr diff <PR>` |
| `/pr-list --head <branch> [--state <state>]` | List the PRs opened from a head branch, as a JSON array | `gh pr list --head <branch> --state <state>` |
| `/pr-review-submit <PR> --verdict <verdict> <body>` or `--body-file <path>` | Post a single PR review carrying a verdict, with the body inline or from a file | `gh pr review <PR>` |
| `/pr-comment <PR> --body-file <path>` | Post one comment on a PR from a file | `gh pr comment <PR> --body-file <path>` |
| `/pr-update <PR> --body-file <path>` | Replace a PR's whole body with a file's contents | `gh pr edit <PR> --body-file <path>` |
| `/pr-ready <N>` | Mark a draft PR ready for review (draft → ready) | `gh pr ready <N>` |
| `/pr-draft <N>` | Convert a ready PR back to a draft (ready → draft) | `gh pr ready <N> --undo` |
| `/pr-ready-to-merge <PR>` | Report an open PR's merge readiness — `mergeable`, `mergeStateStatus`, review decision and check rollup — retrying while GitHub is still computing it | `gh pr view <PR> --json mergeable,mergeStateStatus,…` |
| `/pr-merge-conflicts <PR>` | Enumerate a PR's actual merge conflicts with its base — files and hunks — by a trial merge that is aborted afterwards | `git merge --no-commit --no-ff` in a throwaway worktree |
| `/pr-link-issue <PR> <issue>…` | Ensure the PR body links & closes every issue in its own set | verify/append the missing `Closes #<issue>` lines in the PR body |
| `/pr-closing-issues <PR>` | Report which issues the PR body closes | `gh pr view <PR> --json body` |

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

### `/pr-view <PR> [--json <fields> [--jq <expr>]]`

Reads one PR. With no flags it prints a fixed dump a human can read;
with `--json` it prints exactly the fields named, as `gh pr view --json`
spells them, optionally reduced by a `--jq` expression, for a caller
that needs the body, the reviews, the comments, the state or the refs.
This is the read behind every "look at the PR" step elsewhere in the
marketplace, so a field list a caller used to pass to a raw
`gh pr view` passes through unchanged.

### `/pr-diff <PR>`

Fetches the full unified diff of a pull request via `gh pr diff <PR>`.
This is the diff-fetch that every `theorem-generator` variant,
`theorem-disprover`, `counterexample-verifier`, `issue-fixer`, `code-documenter`,
`style-checker`, and `docs-writer` need
before they read a PR's changes.

### `/pr-list --head <branch> [--state <state>]`

Lists the PRs opened from one head branch as a JSON array, one object
per PR with its number, title, state, refs, merge and close times and
URL; an empty array is the normal "none" answer, not an error. The
match is by branch **name**, not by commit, so a branch deleted and
recreated under the same name matches the PRs of both lives — a caller
gating a deletion on "this branch has a merged PR" needs a second check
on the commits themselves.

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
inline form hands every backtick and `$` in it to the shell. In either
form the script composes the posted body — the verdict line, a blank
line, the caller's text — and hands it to `gh` on stdin, leaving the
caller's own file untouched and writing no scratch copy.

The script does not read the reviewer's login to predict the
self-review refusal. It posts with the verdict's own action and only
re-posts as a comment when that call fails with GitHub's refusal for
**that** action; any other failure stays a failure. Predicting from a
login would have to agree with GitHub about who the author is, and the
server's own answer is the one that counts.

### `/pr-comment <PR> --body-file <path>`

Posts one comment on a PR from a file, then re-reads that comment by
the id GitHub returned and checks its text is the file's. A comment
that did not land as written is reported rather than re-posted, because
a second post would leave two comments if the first did land after
all. The file form is the only form: a comment that quotes a check
name, a hunk or a path carries the characters the shell would read.

### `/pr-update <PR> --body-file <path>`

Replaces a PR's whole body with a file's contents and re-reads the body
to confirm it. Which callers may edit a body, and when — the freeze an
orchestrated run puts on it, the closing lines that must survive — is
the caller's rule, not this verb's; the verb only guarantees that what
GitHub holds afterwards is the file.

### `/pr-ready <N>`

Flips a draft PR into ready-for-review. A draft PR cannot be
auto-merged (the repo's auto-merge workflow filters `isDraft ==
false`), so the flip is the point at which a PR becomes mergeable, and
keeping a PR draft until then is what keeps it inert. Safe to run more
than once — `gh` no-ops if the PR is already ready.

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
