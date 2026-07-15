---
name: pr-link-issue
description: Idempotently ensure a GitHub PR body closes its own issue (appends `Closes #<issue>` if not already present).
---

Ensure a GitHub pull request's body links to and closes the one issue
it resolves, by verifying — and, if needed, appending — a closing
keyword immediately followed by that issue reference in the **PR
body**.

Per GitHub's "Linking a pull request to an issue" docs, a closing
keyword (`close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/
`resolves`/`resolved`, case-insensitive) immediately followed by
`#<issue>` in the **PR description** does two things at once: it
creates the Development-sidebar "linked pull request" **and**
auto-closes the linked issue when the PR merges into the default
branch. A keyword in a *commit message* auto-closes but does **not**
create the sidebar link, which is why this skill writes the PR body,
never a commit. Both effects are intended: the sidebar link is the
whole point, and auto-close-on-merge is the behavior we want.

## Invocation

```text
/pr-link-issue <pr-number> <issue-number>
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.
- `<issue-number>` (required): the issue number the PR resolves —
  the branch's **own** issue only. See "Own issue only" below.

## Own issue only

`<issue-number>` MUST be the branch's own issue — the single issue the
PR resolves — **never** an umbrella, parent, predecessor, or otherwise
"related" issue. Aiming a closing keyword at another issue would
auto-close that issue when this PR merges. Per the corrected
git-workflow rule ("CRITICAL — closing keyword: PR body only, own
issue only"), when the caller-supplied number and the branch name
disagree, **the branch name is the higher-fidelity source of truth**:
the branch-naming convention is `issue-<N>-<slug>`, so `<N>` from the
branch name is the authoritative issue. If the passed
`<issue-number>` conflicts with the `issue-<N>-<slug>` encoded in the
PR's head branch, prefer the branch's `<N>` and note the discrepancy
in the report-back.

## Required repo-config: source-control

This skill only needs to know whether the repo is GitHub-backed — it
does not need the full repo-config reader contract. Read the
`source-control:` field directly from
`.claude/rules/repo-config.md`'s front-matter (a plain YAML
`key: value` line near the top of the file):

- `source-control: GitHub`, or the field is absent/unreadable but
  `gh` is available → proceed.
- `source-control: CodeCommit` → abort cleanly with: "CodeCommit
  source-control selected, but `/pr-link-issue` is GitHub-only and the
  CodeCommit path is not implemented." (This mirrors how
  `issue-developer` handles the CodeCommit PR-create path today.)

## Execution

1. Read `source-control` per "Required repo-config" above and abort
   if it is not GitHub.

2. **Resolve the authoritative issue number.** Fetch the PR's head
   branch and body:

   ```bash
   gh pr view <PR> --json number,headRefName,body
   ```

   If the head branch matches `issue-<N>-<slug>`, use its `<N>` as the
   authoritative issue number (per "Own issue only"); otherwise use
   the passed `<issue-number>`. Call the result `<issue>`.

3. **Idempotent check.** Scan the PR body for a closing keyword
   (`close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/
   `resolves`/`resolved`, case-insensitive) immediately followed by a
   reference to `<issue>` — i.e. the keyword, optional whitespace,
   then `#<issue>` (or `owner/repo#<issue>`, `GH-<issue>`, or the
   issue URL). The reference must resolve to `<issue>` exactly; a
   keyword aimed at a *different* issue number does not satisfy the
   check.

   - **Already linked** → no-op. Report `PR #<PR> already closes
     #<issue>` and stop. Do not append a duplicate keyword.

4. **Append.** If no such keyword-reference pair is present, append
   `Closes #<issue>` to the existing PR body (preserve the current
   body; add the line separated by a blank line) and write it back:

   ```bash
   gh pr edit <PR> --body "<existing-body>

   Closes #<issue>"
   ```

   Preserve the existing body verbatim; only add the trailing
   `Closes #<issue>` line. Do not add a closing keyword aimed at any
   other issue, and never write the keyword into a commit message.

5. Report back a single line: whether the PR was already linked or the
   `Closes #<issue>` line was appended, naming `<PR>` and `<issue>`.
