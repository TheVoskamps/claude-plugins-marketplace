# github-prs

GitHub-only skills for the operations a pull request goes through:
create it (as a draft, closing its own issue set), fetch its diff,
submit a review with a verdict, flip it between draft and
ready-for-review, link it to the issues it resolves via one closing
keyword each in the PR body, and read those closing lines back to say
which issues it closes.

These skills serve the `/sdlc:orchestrate` flow and its agents. The
`issue-developer` opens the PR. The
`theorem-based-pr-reviewer` posts the single review that carries the
verdict, and — when run standalone on a bare PR number — reads the
PR's closing lines to learn which issues it claims; the
`theorem-generator`, `theorem-disprover`, and `counterexample-verifier`
agents it spawns fetch the diff, as do the `issue-fixer` and
`doc-updater`. The orchestrator keeps PRs draft through the review/fix
loop, reads those same closing lines for the issues it flips to In
Review, and only flips draft → ready once the human blesses the PR at
end-of-loop. Each skill is still a standalone verb usable by a human
or any caller.

## One PR, one issue set

A PR in this flow delivers a **batch**: an ordered set of one or more
issues implemented on one branch. A batch of one is the ordinary
single-issue PR, so nothing below is extra work for that case.

`git-tools:git-branch-create` encodes the set in the branch name, and
`git-tools:git-issues-from-branch` — its inverse — recovers it. That
skill is also where the **issue-to-branch reconciliation rule** is
applied: the rule itself is global, stated normatively in
`rules/git-workflow.md` → "Issue References", and neither skill here
restates it. `/pr-create` and `/pr-link-issue` each hand
`git-issues-from-branch` the branch plus their own claim — the numbers
their caller passed, which a caller of either always has in hand — and
act on the outcome it reports. Neither parses a branch name and
neither re-derives the resolution.

That cross-plugin invocation is why this plugin's `plugin.json`
declares a `dependencies` edge on `git-tools`: the edge guarantees the
skill is installed and enabled wherever these skills run (see
`docs/plugin-authoring-constraints.md` → "`dependencies` coordinates
install/enable, not files").

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
lines, so `/pr-link-issue`'s idempotency check invokes it instead of
scanning the body itself. `/pr-create` is not a consumer — it writes
closing lines and never reads them.

Every skill is GitHub-only **by design**: each is built directly on the
`gh` CLI, and there is no CodeCommit (or other source-control) branch
in any of them. CodeCommit is deliberately out of scope here, not
deferred.

## Config: read internally, not by the caller

`pr-ready`, `pr-draft`, `pr-diff`, `pr-review-submit`, and
`pr-closing-issues` take everything they need as arguments and read no
configuration at all. Only `pr-create` reads repo-config —
`default-pr-target-branch` and `issue-link-prefix` — and it does so
**internally**, via a lightweight inline parse of just those two
front-matter lines, not the `issues` plugin's full
`skills/lib/repo-config.md` reader contract (that lib lives inside the
`issues` plugin and isn't reachable across the plugin sandbox boundary
— see `docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). Neither `pr-create` nor `pr-link-issue`
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
| `/pr-review-submit <PR> <verdict> <body>` or `--body-file <path>` | Post a single PR review carrying a verdict, with the body inline or from a file | `gh pr review <PR>` |
| `/pr-ready <N>` | Mark a draft PR ready for review (draft → ready) | `gh pr ready <N>` |
| `/pr-draft <N>` | Convert a ready PR back to a draft (ready → draft) | `gh pr ready <N> --undo` |
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
This is the diff-fetch that `theorem-generator`, `theorem-disprover`,
`counterexample-verifier`, `issue-fixer`, and `doc-updater` need
before they read a PR's changes.

### `/pr-review-submit <PR> <verdict> <body>` / `--body-file <path>`

Posts a **single** pull-request review carrying both a verdict and a
body in one call. Approving uses `--approve`, requesting changes uses
`--request-changes`, and a verdict-less note uses `--comment`. Because
`gh` blocks `--approve` when the reviewer is the PR author, the skill
states an approve verdict in the review body via `--comment` in that
self-review case rather than failing.

The body arrives in exactly one of two forms, and both work for all
three verdicts: inline as the last argument, or as
`--body-file <path>` naming a file that holds it.
`sdlc:theorem-based-pr-reviewer` uses the file form — it stages the
review under `.claude/tmp/<task-slug>/` and posts it by path, because
a real round's body is tens of kilobytes of Markdown that quotes code
throughout, and the inline form hands every backtick and `$` in it to
the shell. In the file form the self-review downgrade composes a
**new** file carrying the `APPROVED` line ahead of the caller's text,
leaving the caller's own file untouched.

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
the closing-keyword-immediately-before-reference syntax
(`rules/git-workflow.md` → "Issue References" is the authority). It is
the one place in this marketplace that syntax is applied to a PR body,
so `/pr-link-issue`, `sdlc:theorem-based-pr-reviewer` running
standalone, and
`/sdlc:orchestrate`'s end-of-loop status flip all invoke it rather
than scanning a body themselves. A single-PR primitive: a caller
holding several PRs loops.
