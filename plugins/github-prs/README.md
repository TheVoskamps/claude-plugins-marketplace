# github-prs

GitHub-only skills for the operations a pull request goes through:
create it (as a draft, closing its own issue set), fetch its diff,
submit a review with a verdict, flip it between draft and
ready-for-review, and link it to the issues it resolves via one closing
keyword each in the PR body.

These skills serve the `/sdlc:orchestrate` flow and its agents — the
`issue-developer` opens the PR, the `pr-reviewer` diffs and reviews it,
the `issue-fixer` and `doc-updater` diff it, and the orchestrator keeps
PRs draft through the review/fix loop and only flips draft → ready once
the human blesses the PR at end-of-loop — but each skill is a
standalone verb usable by a human or any caller.

## One PR, one issue set

A PR in this flow delivers a **batch**: an ordered set of one or more
issues implemented on one branch. A batch of one is the ordinary
single-issue PR, so nothing below is extra work for that case.

`git-tools:git-branch-create` encodes the set in the branch name —
`issue-<N1>-<N2>-…-<Nk>-<slug>`, or `issue-<N>-<slug>` at k=1 — and
`/pr-create` and `/pr-link-issue` recover it by the same parsing rule:
after the `issue-` marker, the leading run of all-numeric
hyphen-separated tokens is the set, and everything from the first
non-numeric token onward is the slug. Both compare as a **set**; the
order in the name is the developer's implementation order and carries
no meaning for them.

The branch's set is a **maximum, not an equality**: a PR may close a
subset of it, never a superset. That is what lets a member be dropped
mid-flight without renaming a branch that already carries commits and
a PR.

Each member needs **its own closing keyword** — GitHub links only a
reference that carries a keyword immediately before it, so
`Closes #196, #201` links `#196` and silently leaves `#201` unlinked.
Both skills therefore write one `Closes #<issue>` line per issue.

Every skill is GitHub-only **by design**: each is built directly on the
`gh` CLI, and there is no CodeCommit (or other source-control) branch
in any of them. CodeCommit is deliberately out of scope here, not
deferred.

## Config: read internally, not by the caller

Every skill but `pr-create` — `pr-ready`, `pr-draft`, `pr-link-issue`,
`pr-diff`, `pr-review-submit` — takes everything it needs as arguments
and reads no configuration at all. Only `pr-create` reads
repo-config — `default-pr-target-branch` and `issue-link-prefix` — and
it does so **internally**, via a lightweight inline parse of just
those two front-matter lines, not the `issues` plugin's full
`skills/lib/repo-config.md` reader contract (that lib lives inside the
`issues` plugin and isn't reachable across the plugin sandbox boundary
— see `docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). The caller just invokes the skill with the issue/PR
number — the operation owns its own config read where it needs one.
This is the whole point of the split: a caller no longer parses
repo-config to hand-roll a raw `gh pr create`/`gh pr diff`/`gh pr
review`.

## Skills

| Skill | Purpose | Underlying command |
| ------- | --------- | -------------------- |
| `/pr-create <issue>… <branch>` | Open a draft PR for a branch against the right base, closing its own issue set | `gh pr create --draft --base <target>` |
| `/pr-diff <PR>` | Fetch a PR's full diff | `gh pr diff <PR>` |
| `/pr-review-submit <PR> ...` | Post a single PR review carrying a verdict | `gh pr review <PR>` |
| `/pr-ready <N>` | Mark a draft PR ready for review (draft → ready) | `gh pr ready <N>` |
| `/pr-draft <N>` | Convert a ready PR back to a draft (ready → draft) | `gh pr ready <N> --undo` |
| `/pr-link-issue <PR> <issue>…` | Ensure the PR body links & closes every issue in its own set | verify/append the missing `Closes #<issue>` lines in the PR body |

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
report-back. See the skill for the closing-keyword rule (PR body only,
own issue set only, never a commit).

### `/pr-diff <PR>`

Fetches the full unified diff of a pull request via `gh pr diff <PR>`.
This is the diff-fetch that `pr-reviewer`, `issue-fixer`, and
`doc-updater` need before they read a PR's changes.

### `/pr-review-submit <PR> ...`

Posts a **single** pull-request review carrying both a verdict and a
body in one call. Approving uses `--approve`, requesting changes uses
`--request-changes`, and a verdict-less note uses `--comment`. Because
`gh` blocks `--approve` when the reviewer is the PR author, the skill
states an approve verdict inline via `--comment` in that
self-review case rather than failing.

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

Set-idempotent verify/append. Reads the PR body and checks each passed
issue for a closing keyword immediately followed by a reference to it;
members that already have one are left alone, the missing ones get a
`Closes #<issue>` line appended, and a body that already covers every
member is a no-op. A closing keyword in the PR body is GitHub's
sanctioned mechanism for both the Development-sidebar "linked pull
request" **and** the auto-close-on-merge to the default branch.

Every `<issue>` must be a member of the branch's **own** set — never
an umbrella/parent/related issue. The passed numbers select which
members to ensure; the head branch's encoded set bounds which are
allowed, and is the higher-fidelity source of truth when they
disagree. Passing a subset is how a deliberately deferred member stays
un-closed.
