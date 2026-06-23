---
name: issue-update
description: Update a single issue's title, body (replace/append/prepend), labels, or assignees in one invocation.
---

Update fields on a single existing issue: title, full body
replacement, additive body edits (append/prepend a line), label
add/remove, and assignee add/remove. One issue per invocation; loop
in conversation when editing multiple issues.

See `skills/lib/issue.md` for the shared GraphQL templates, tracker
dispatch, and error wording. This file documents only what is
specific to `/issue-update`.

Read `skills/lib/repo-config.md` for the repo-config read contract;
this skill requires **schema-version 6** and uses that library's
canonical read sequence and abort messages for
`.claude/rules/repo-config.md`.

## Invocation

```text
/issue-update <N>
              [--title "..."]
              [--body-file PATH]
              [--append "line to append"]
              [--prepend "line to prepend"]
              [--add-labels a,b] [--remove-labels a,b]
              [--add-assignees u1] [--remove-assignees u2]
```

- `<N>` (required): issue number in the current repo.
- `--title` (optional): replace the title.
- `--body-file` (optional): full-replace the body with the contents of
  the given file.
- `--append` (optional): append one line to the current body. Multiple
  `--append` flags concatenate in CLI order, each on its own line.
- `--prepend` (optional): prepend one line to the current body.
  Multiple `--prepend` flags stack in CLI order; the first `--prepend`
  ends up as the first line.
- `--add-labels` / `--remove-labels` (optional): comma-separated label
  names to add or remove.
- `--add-assignees` / `--remove-assignees` (optional): comma-separated
  GitHub usernames to add or remove.

At least one update flag must be passed. If none are present, abort
with a short usage reminder.

## Flag compatibility

- `--body-file` is **mutually exclusive** with `--append` and
  `--prepend`. A full replace makes line-additive edits ambiguous.
  Passing both aborts with:

  > `--body-file` cannot be combined with `--append` or `--prepend`
  > (full-replace vs. line-additive). Run them in separate
  > invocations.

- All other flag combinations are allowed and are applied in a single
  invocation.

## Tracker dispatch

Apply the standard `issues:` switch from `skills/lib/issue.md`.
Under `issues == Jira`, follow the Jira backend path documented
there (`skills/lib/issue.md` → "Jira backend"), which talks to Jira
via `acli` (the `/issues-jira:jira-lib` skill); it no longer aborts.

## Execution (GitHub backend)

1. **Pre-edit fetch.** Decide which fields need to be read from the
   issue before the edit, based on the flags in play:

   - `--append` or `--prepend` → fetch `body`.
   - `--add-assignees` or `--remove-assignees` → fetch `assignees`.
   - `--add-labels` or `--remove-labels` → fetch `labels`.

   Fold all needed fields into a **single** `gh issue view` call to
   keep the round-trip count low. For example, when both
   `--prepend` and `--add-assignees` are in play, run

   ```bash
   gh issue view <N> --json body,assignees
   ```

   and parse out each field as needed (e.g.
   `--jq '{body: .body, assignees: [.assignees[].login]}'`).

   When only `--body-file`, `--title`, or no body/list flags are in
   play, skip the pre-edit fetch entirely — there is nothing to
   compute against.

   Capture the pre-edit assignee logins (as a set of strings) and
   label names (as a set of strings) for later use in the post-edit
   delta check. The pre-edit body, if fetched, feeds step 2.

2. **Compute the new body**:
   - If `--body-file`: read the file. That's the new body.
   - Else if `--append` and/or `--prepend`: start from the current
     body. Build a prepend-prefix by concatenating the `--prepend`
     values in CLI order, each terminated by `\n` (so the first
     `--prepend` ends up as the first line of the new body). Build an
     append-suffix by joining the `--append` values in CLI order with
     `\n` between them (so the first `--append` is the first appended
     line). The new body is
     `<prepend-prefix><current-body><separator><append-suffix>`,
     where `<separator>` is the empty string if `<current-body>` ends
     with `\n` (the GitHub default — the trailing newline already
     separates the body from the first appended line, so do not insert
     an extra blank line) and `\n` otherwise. If the new body does
     not end with `\n`, add one so it matches GitHub's stored-body
     convention.
   - Else: skip the body update entirely.

3. **Apply edits via `gh issue edit`** in one call where possible.
   `gh issue edit` supports `--title`, `--body-file`, `--add-label`,
   `--remove-label`, `--add-assignee`, and `--remove-assignee` in a
   single invocation:

   ```bash
   gh issue edit <N> \
     [--title "<new-title>"] \
     [--body-file <path-or-tmpfile>] \
     [--add-label "<comma-list>"] \
     [--remove-label "<comma-list>"] \
     [--add-assignee "<comma-list>"] \
     [--remove-assignee "<comma-list>"]
   ```

   When the computed new body comes from `--append`/`--prepend`, write
   it to a temp file under `.claude/tmp/issue-update-<N>/` and pass
   `--body-file <tmpfile>`. Do **not** use `--body "..."` for
   multi-line content — Markdown and shell quoting interact badly.
   Clean the tempfile up on success; leave it in place on failure for
   inspection.

   Build the invocation only from flags the user actually passed. Do
   not pass empty values.

4. **Issue not found**: if `gh issue edit` returns
   `could not resolve to an Issue`, emit the "Issue not found"
   error from the catalogue in `skills/lib/issue.md` and abort.

5. **Post-edit delta check** (only when one or more of
   `--add-assignees`, `--remove-assignees`, `--add-labels`, or
   `--remove-labels` was passed).

   `gh issue edit` silently accepts unknown assignee logins and
   unknown labels: it exits zero and prints the issue URL even when
   the assignee/label is not valid on the repo (typo, wrong username,
   user lacks assignee permission, label does not exist). Without a
   post-check, the skill would report "assignees added: `<login>`"
   purely based on the CLI input, not on what actually landed.

   - **Re-fetch the affected fields** in a single `gh issue view`
     call. Pick only the fields whose flags were in play, e.g.
     `gh issue view <N> --json assignees,labels` when both kinds were
     touched, or `--json assignees` when only assignee flags ran.
   - **Compute the actual deltas** against the pre-edit sets captured
     in step 1:
     - actual-added-assignees = post − pre
     - actual-removed-assignees = pre − post
     - actual-added-labels = post − pre
     - actual-removed-labels = pre − post

     Set membership is case-insensitive for label names (GitHub label
     names are case-insensitive) and exact for assignee logins
     (GitHub logins are case-insensitive on input but echoed back in
     their canonical casing — match against the canonical login).

     When comparing requested assignee logins against the
     actual-added/actual-removed sets, lowercase both sides before
     comparison (GitHub logins are case-insensitive on input, so
     e.g. `Evoskamp` and `evoskamp` are the same user). The mismatch
     report line (see "Output" below) should echo the user's input
     string verbatim so they recognize what they typed.
   - **Compare against the requested deltas** (the comma-separated
     values the user passed on each flag):
     - For `--add-assignees`: any requested login NOT in
       actual-added-assignees AND NOT already in the pre-edit
       assignee set is a **failed-add**.
     - For `--remove-assignees`: any requested login NOT in
       actual-removed-assignees AND still present in the post-edit
       assignee set (i.e. it was supposed to leave but didn't) is a
       **failed-remove**. A requested login that was not on the
       issue to begin with is a no-op, not a failure.
     - Same shape for `--add-labels` and `--remove-labels`.
   - **Surface mismatches in the output.** See the "Output" section
     below for the exact line format. Do **not** abort — the skill
     still exits zero. The mismatch is information; the edit
     succeeded for what GitHub accepted.

## Output

Print a single line per field that changed:

```text
Updated issue #<N>:
  title:           <new title>
  body:            replaced (<lines> lines)              # --body-file
  body:            appended <N> line(s), prepended <M> line(s)
  labels added:    a, b
  labels removed:  c
  assignees added: u1
  assignees removed: u2
```

Then a blank line and the issue URL.

Skip fields that didn't change. When only one flag was passed, only
one summary line shows.

The "labels added", "labels removed", "assignees added", and
"assignees removed" lines reflect what **actually landed** on the
issue per the post-edit delta check (step 5 of Execution), not the
raw CLI input. A requested login or label that didn't land does
**not** appear on the corresponding "added"/"removed" line; it is
surfaced on its own mismatch line instead. If every requested
login/label in a given add/remove direction failed to land, the
corresponding line is omitted entirely (since nothing actually
changed in that direction).

When the post-edit delta check finds mismatches, append one
mismatch line per direction immediately under the relevant
"added"/"removed" line. Format:

```text
Updated issue #<N>:
  assignees added: evoskamp
  assignees requested but not added: edwinvoskamp (not a valid
    assignee on this repo, or permission denied)
  labels requested but not added: bugg (not a valid label on this repo)
  labels requested but not removed: needs-triage (label is on the
    issue but could not be removed — permission denied, or
    label-management is restricted)
```

The parenthetical hint differs by direction:

- **assignees requested but not added** — `(not a valid assignee on
  this repo, or permission denied)`
- **assignees requested but not removed** — `(assignee is on the
  issue but could not be removed — permission denied, or some other
  gh-side filter)`
- **labels requested but not added** — `(not a valid label on this
  repo)`
- **labels requested but not removed** — `(label is on the issue but
  could not be removed — permission denied, or label-management is
  restricted)`

List multiple failed names comma-separated on a single mismatch line
(e.g. `assignees requested but not added: alice, bob (not a valid
assignee on this repo, or permission denied)`).

The skill still exits **zero** when mismatches are present — the
`gh issue edit` call succeeded for whatever GitHub accepted; the
mismatch is information for the user, not an error.
