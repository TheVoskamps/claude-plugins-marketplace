# github-prs

GitHub-only skills for the operations a pull request goes through:
create it (as a draft, closing its own issue), fetch its diff, submit a
review with a verdict, flip it between draft and ready-for-review, and
link it to the issue it resolves via a closing keyword in the PR body.

These skills serve the `/sdlc:orchestrate` flow and its agents — the
`issue-developer` opens the PR, the `pr-reviewer` diffs and reviews it,
the `issue-fixer` and `doc-updater` diff it, and the orchestrator keeps
PRs draft through the review/fix loop and only flips draft → ready once
the human blesses the PR at end-of-loop — but each skill is a
standalone verb usable by a human or any caller.

Every skill is GitHub-only **by design**: each is built directly on the
`gh` CLI, and there is no CodeCommit (or other source-control) branch
in any of them. CodeCommit is deliberately out of scope here, not
deferred.

## Config: read internally, not by the caller

Five of the six skills (`pr-ready`, `pr-draft`, `pr-link-issue`,
`pr-diff`, `pr-review-submit`) take everything they need as arguments
and read no configuration at all. Only `pr-create` reads
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
|-------|---------|--------------------|
| `/pr-create <issue> <branch>` | Open a draft PR for a branch against the right base, closing its own issue | `gh pr create --draft --base <target>` |
| `/pr-diff <PR>` | Fetch a PR's full diff | `gh pr diff <PR>` |
| `/pr-review-submit <PR> ...` | Post a single PR review carrying a verdict | `gh pr review <PR>` |
| `/pr-ready <N>` | Mark a draft PR ready for review (draft → ready) | `gh pr ready <N>` |
| `/pr-draft <N>` | Convert a ready PR back to a draft (ready → draft) | `gh pr ready <N> --undo` |
| `/pr-link-issue <PR> <issue>` | Ensure the PR body links & closes its own issue | verify/append `Closes #<issue>` in the PR body |

### `/pr-create <issue> <branch>`

Opens a pull request for `<branch>` as a **draft**, against the base
branch read from `default-pr-target-branch` in repo-config, with a
`Closes <link-prefix><issue>` line in the PR body so the PR links and
auto-closes its own issue on merge. Reads `default-pr-target-branch`
and `issue-link-prefix` internally via a lightweight inline parse (see
"Config: read internally, not by the caller" above). `<issue>` must be
the branch's own issue (`issue-<N>-<slug>`); when the passed `<issue>`
and the branch's encoded `<N>` disagree, the branch name is the
higher-fidelity source of truth. See the skill for the closing-keyword
rule (PR body only, own issue only, never a commit).

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
