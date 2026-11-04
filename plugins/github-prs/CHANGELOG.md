# github-prs changelog

## 0.11.1 — 2026-10-28

Documentation only: text follows a change to `sdlc`'s review agents.

## 0.11.0 — 2026-10-11

`/pr-create` and `/pr-link-issue` reject a comma-separated issue list as
a usage error naming the token. Separate issues with spaces.

## 0.10.0 — 2026-10-08

Adds `/pr-files`, which lists every file a PR changes with its change
type, additions, deletions and path. It pages past the 100 files
`pr-view --json files` silently stops at. It takes over the changed-files
read `sdlc`'s reviewer assembled by hand.

Exit statuses change, so a caller that branches on them must update:

- Exit 1 is now a generic failure: any command that failed, with a line
  naming it. No tool's raw status reaches the caller.
- Exit 3 is now the verb's own negative outcome: a change that did not
  land, a PR that is not open, or a merge state still `UNKNOWN`.
- Bash's own 126, 127 and 128+N can still reach a caller.

## 0.9.2 — 2026-10-07

`/pr-link-issue` is idempotent when its script is called directly: it
appends a `Closes` line only for an issue the body does not already
close, and writes nothing when all are closed.

`/pr-closing-issues` now reports from the same recognizer, which is
stricter than GitHub's linker. A bare number, `GH-N`, a word between
keyword and reference, or a reference to another repository counts as
not closed, so a miss costs one extra line and never a missing one.

## 0.9.1 — 2026-10-07

A PR reference's repository part is validated per part, by what GitHub
allows an owner and a repository name and by DNS rules for a host. A
repository name may start with `-`, while an owner may not.

Some references accepted before are now refused: an owner holding `_`,
`.` or `--`, an over-length part, and a host holding `_` or with a `-`
at either end of a label.

## 0.9.0 — 2026-10-05

Every verb that takes a PR accepts a reference that may name the
repository: `N`, `#N`, `repo#N`, `owner/repo#N`, `host/owner/repo#N` or
the PR's URL. A malformed reference, an issue URL included, is a usage
error before any `gh` call.

- A reference naming a repository sends every call there.
- `/pr-view --ref` prints the canonical `host/owner/repo#N`, and the
  default dump opens with it. A fork PR prints its base repository.
- `/pr-merge-conflicts` works on another repository's PR without moving
  any `origin/*` ref.

## 0.8.2 — 2026-10-04

`gh api` calls now go to the checkout's host, so verbs that make them
work in a checkout on GitHub Enterprise instead of querying the wrong
host and failing.

`/pr-merge-conflicts` documents that a rebase inverts the side labels
its report shows: resolve a rebase stop by content, never by the label.

## 0.8.1 — 2026-10-03

Documentation only: the README notes one more use of the closing lines.

## 0.8.0 — 2026-09-27

Every verb now runs a bundled script that makes the `gh` call itself,
with one exit-status table across verbs, and every verb runs under
bash 3.2.

- New verbs take over the raw PR calls that `sdlc`, `git-tools` and
  `cc-tools` assembled themselves: `/pr-view` prints a PR or the fields
  you name, `/pr-update` replaces its body from a file, `/pr-comment`
  posts a comment from a file, and `/pr-list` lists the PRs for a branch.
- A verb that changes a PR re-reads it and reports a change that did not
  land.
- Bodies reach `gh` by file or on stdin, so the shell never reads them,
  and `/pr-review-submit` writes no scratch copy.
- `/pr-review-submit` no longer compares logins: it posts the verdict
  and falls back to a comment only when GitHub refuses it as self-review.

## 0.7.1 — 2026-09-21

Documentation only: text names the agents that now run the readiness
gate and watch the merge.

## 0.7.0 — 2026-09-19

Adds two read-only verbs for whether a PR can move forward. Neither
rebases, resolves or pushes.

- `/pr-ready-to-merge` reports `mergeable` and `mergeStateStatus`, with
  `reviewDecision` and the check rollup so a caller can tell what a
  `BLOCKED` is blocked on. It retries on an announced schedule while the
  state is `UNKNOWN`, and refuses a PR that is not open.
- `/pr-merge-conflicts` lists the conflicting files and hunks from a
  trial merge in a throwaway worktree, which it aborts and removes. It
  also clears a worktree an interrupted run left behind.

## 0.6.3 — 2026-09-17

Documentation only: one wording change in `/pr-ready`.

## 0.6.2 — 2026-09-11

Documentation only: text names the agents that now consume `/pr-diff`
and no longer cites documents outside the plugin.

## 0.6.1 — 2026-09-10

Documentation only: text describes what the reviewer now posts by file.

## 0.6.0 — 2026-08-26

`/pr-review-submit` takes the verdict as a named slot, so callers must
change: `--verdict approve`, `--verdict request_changes` or
`--verdict comment`.

- A missing, repeated or unrecognized verdict aborts without posting.
- An author's `request_changes` is now handled like `approve`: GitHub
  refuses both from a PR's own author, so each is posted as a comment
  rather than failing.
- The body opens with the verdict word on every post.
- The report states the review state GitHub actually created.

## 0.5.0 — 2026-08-24

`/pr-create` reads `.issues/repo-config.md` instead of
`.claude/rules/repo-config.md`. There is no fallback: a repo that has
not moved its file gets the abort naming `/repo-config`.

## 0.4.0 — 2026-08-22

`/pr-review-submit` accepts the body as `--body-file <path>`, for a body
whose backticks and `$` would not survive the shell. Supplying both
forms, or neither, aborts without posting. The caller's file is left
untouched.

## 0.3.3 — 2026-08-20

Documentation only: text names the renamed PR reviewer.

## 0.3.2 — 2026-08-13

Documentation only: text adds a new consumer of `/pr-diff`.

## 0.3.1 — 2026-08-11

Documentation only: text names the new review pipeline's agents.

## 0.3.0 — 2026-08-03

A PR can now close a batch of issues worked on one branch. A single
issue behaves as before.

- `/pr-create` and `/pr-link-issue` take several issues and write one
  `Closes` line each, since GitHub links only a reference with its own
  keyword.
- Which issues may be closed is settled against the branch's own set. A
  number outside it never gets a closing line and is named in the
  report; with no safe resolution, no PR opens and no body changes.
- `/pr-create` names a branch member left unclaimed in the PR body.
- New `/pr-closing-issues` reports which issues a PR body closes.
- The plugin now depends on `git-tools`.

## 0.2.1 — 2026-08-01

Documentation only: README table formatting.

## 0.2.0 — 2026-07-16

The plugin as added: GitHub-only skills for pull-request operations, so
callers stop assembling raw `gh pr` calls.

- `/pr-create` opens a draft PR against the configured base, with a
  closing keyword for the branch's own issue in the body.
- `/pr-diff` fetches a PR's full diff.
- `/pr-review-submit` posts one review carrying a verdict and a body.
- `/pr-ready` and `/pr-draft` flip a PR between draft and ready.
- `/pr-link-issue` ensures the PR body closes its own issue.
