---
name: pr-link-issue
description: Idempotently ensure a GitHub PR body closes every issue in its own issue set (appends the `Closes #<issue>` lines that are missing).
---

# PR Link Issue

Ensure a GitHub pull request's body links to and closes each issue it
resolves, by verifying — and, if needed, appending — a closing keyword
immediately followed by that issue reference in the **PR body**, once
per issue.

Per GitHub's "Linking a pull request to an issue" docs, a closing
keyword immediately followed by an issue reference in the **PR
description** does two things at once: it creates the
Development-sidebar "linked pull request" **and** auto-closes the
linked issue when the PR merges into the default branch. A keyword in
a *commit message* auto-closes but does **not** create the sidebar
link, which is why this skill writes the PR body, never a commit. Both
effects are intended: the sidebar link is the whole point, and
auto-close-on-merge is the behavior we want.

Each issue needs **its own keyword**, so this skill writes one
`Closes #<issue>` line per issue rather than one line listing several.
The syntax that makes that necessary is stated once, in
`github-prs:pr-closing-issues` → "The syntax", over
`rules/git-workflow.md` as its authority — and reading a body back for
the lines it already carries goes through that same skill rather than
a scan of this one's own (see step 2 of "Execution").

## Invocation

```text
/pr-link-issue <pr-number> <issue-number>…
```

- `<pr-number>` (required): the pull-request number in the current
  repo, with or without a leading `#`.
- `<issue-number>…` (required): one or more issue numbers the PR
  resolves — members of the branch's **own** issue set only, separated
  by spaces or commas. See "Own issue set only" below.

## Own issue set only

Every issue this skill writes a closing keyword for MUST be a member
of the branch's own issue set — **never** an umbrella, parent,
predecessor, or otherwise "related" issue. Aiming a closing keyword at
another issue would auto-close that issue when this PR merges, which
is what the closing-keyword rule in `rules/git-workflow.md` — PR body
only, the branch's own issue set only — exists to prevent.

That rule also settles what happens when the caller's numbers and the
branch name disagree, and it is **global** rather than this skill's:
`rules/git-workflow.md` → "Issue References" is the authority, and
`/git-tools:git-issues-from-branch` is the one skill that applies it.

This skill's part is small. Its **claim** is the caller-supplied
numbers — a caller of `/pr-link-issue` always has the issues in hand,
so there is nothing to look up. It hands that claim to
`/git-tools:git-issues-from-branch` alongside the PR's head branch,
and acts on what comes back. It never parses a branch name and never
re-derives the resolution. That skill reads
`issue-branch-naming-prefix` from repo-config internally; this one
reads no config of its own.

## Execution

1. **Resolve the set of issues to ensure.** Fetch the PR's head branch
   and body:

   ```bash
   gh pr view <PR> --json number,headRefName,body
   ```

   Invoke `/git-tools:git-issues-from-branch <headRefName>
   <issue-number>…` — the head branch first, the caller-supplied
   numbers after it as the claim.

   - **A resolved set** is the set to ensure. Call it `<issues>`.
   - **No safe resolution** — leave the body untouched. Report that
     outcome with both sets exactly as the skill named them, and stop;
     the caller re-invokes with numbers drawn from the branch's set.

   Note the "claimed outside the branch set" numbers it reports: those
   never get a closing line, and the refusal is named in the
   report-back.

2. **Idempotent check.** Invoke `/github-prs:pr-closing-issues <PR>` —
   the one skill that reads a PR body's closing lines — and take the
   set it reports as what the body already closes. Members of
   `<issues>` in that set are already linked and are left alone; the
   rest are the missing ones.

   - **Every member already linked** → no-op. Report `PR #<PR> already
     closes <issues>` and stop. Do not append a duplicate keyword.

3. **Append the missing ones.** Append one `Closes #<issue>` line for
   each member step 2 found missing — and only those — to the existing
   PR body (preserve the current body; add the lines separated from it
   by a blank line) and write it back:

   ```bash
   gh pr edit <PR> --body "<existing-body>

   Closes #<issueA>
   Closes #<issueB>"
   ```

   Preserve the existing body verbatim; only add the missing closing
   lines. Never add a closing keyword aimed at an issue outside the
   branch's set, and never write the keyword into a commit message.

4. Report back a single line: which members were already linked and
   which had a `Closes #<issue>` line appended, naming `<PR>`, plus
   any caller-supplied number step 1 reported as sitting outside the
   branch's set. If step 1 gave no safe resolution, the body is
   unchanged — report that outcome instead, with both sets.
