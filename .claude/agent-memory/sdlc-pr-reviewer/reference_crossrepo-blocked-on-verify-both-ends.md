---
name: crossrepo-blocked-on-verify-both-ends
description: An issue's cross-repo "Blocked on" (usually a ~/.claude rule amendment in TheVoskamps/claude-config) is verified at the deployed file AND the companion repo's PR list; a staged-but-unmerged companion PR turns the finding into a Medium sequencing note, not a missing-work High
metadata:
  type: reference
---

Issues in this repo sometimes carry a prose "Blocked on" naming a
change in `TheVoskamps/claude-config` (the source repo for
`~/.claude/rules/*`), because cross-repo blockers cannot be expressed
as blocked-by edges. A PR that implements the issue will cite the
amended rule wording as if it already landed (e.g. #224's pr-create
citing "the branch's own issue set only").

Verify the precondition at both ends, two cheap calls:

1. **The deployed file is the operative territory.** Grep the live
   `~/.claude/rules/<file>.md` for the old wording — that is what
   every session actually loads, regardless of what the claude-config
   repo's main says. (Reading outside the repo is allowed; writing is
   not.)
2. **Check whether the amendment is staged.** `gh pr list --repo
   TheVoskamps/claude-config --state all --limit 10 --json
   number,title,state` — the companion change is usually an already
   open PR authored in the same working session (for #224 it was
   claude-config#38, opened minutes after the marketplace PR).

Grading: unmet-and-unstaged would be BLOCKED-shaped (remedy outside
the repo, human decision). Unmet-but-staged is a **Medium
merge-ordering finding** — nothing in the diff to change, the remedy
is "merge the companion first", and it dissolves the moment that PR
lands and deploys. Don't grade the citation of the future wording as
a false-claim High when the companion PR exists; do flag that the PR
body omits the ordering constraint if it does.

The session-start system-reminder snapshot of `~/.claude/rules/*` is
NOT the live file: on #224 round 2 the snapshot still showed the old
singular "own issue only" heading while a live grep showed the
amended "own issues only" / "issue set" wording already deployed
(claude-config#38 merged between rounds). Never grade a deployment
claim from the snapshot — grep the file on disk.
