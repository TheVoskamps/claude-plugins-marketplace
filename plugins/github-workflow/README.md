# github-workflow

Thin GitHub-only skills for managing a pull request's lifecycle: flip
a PR between draft and ready-for-review, and link a PR to the issue it
resolves via a closing keyword in the PR body.

These skills serve the `/sdlc:orchestrate` flow (the orchestrator
keeps PRs draft through the review/fix loop, links each PR to its
issue, and only flips draft → ready once the human blesses the PR at
end-of-loop), but each skill is a standalone verb usable by a human or
any caller.

Every skill reads `.claude/rules/repo-config.md` (per the
`skills/lib/repo-config.md` reader contract, schema-version 6) for
`source-control` and is **GitHub-only**: on `source-control !=
GitHub` it aborts cleanly (CodeCommit → a "not implemented" abort,
mirroring how `issue-developer` handles the CodeCommit PR-create path
today).

## Skills

| Skill | Purpose | Underlying command |
|-------|---------|--------------------|
| `/pr-ready <N>` | Mark a draft PR ready for review (draft → ready) | `gh pr ready <N>` |
| `/pr-draft <N>` | Convert a ready PR back to a draft (ready → draft) | `gh pr ready <N> --undo` |
| `/pr-link-issue <PR> <issue>` | Ensure the PR body links & closes its own issue | verify/append `Closes #<issue>` in the PR body |

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

### `/pr-link-issue <PR> <issue>`

Idempotent verify/append. Reads the PR body; if it already contains a
closing keyword immediately followed by a reference to `<issue>`, it
no-ops. Otherwise it appends `Closes #<issue>` to the PR body. A
closing keyword in the PR body is GitHub's sanctioned mechanism for
both the Development-sidebar "linked pull request" **and** the
auto-close-on-merge to the default branch.

`<issue>` must be the branch's **own** issue — the one issue the PR
resolves, never an umbrella/parent/related issue. When the passed
`<issue>` and the PR's head branch (`issue-<N>-<slug>`) disagree, the
branch name is the higher-fidelity source of truth.
