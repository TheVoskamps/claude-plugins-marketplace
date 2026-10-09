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
The bundled script reads the body back for the lines it already
carries before writing, through `gp_closing_issues` — the parse the
`pr-closing-issues` script shares — so it appends only what is missing
and is idempotent on its own.

## Invocation

```text
/pr-link-issue <PR> <issue-number>…
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.
- `<issue-number>…` (required): one or more issue numbers the PR
  resolves — members of the branch's **own** issue set only, separated
  by spaces or commas. See "Own issue set only" below.

## Own issue set only

Every issue this skill writes a closing keyword for MUST be a member
of the branch's own issue set — **never** an umbrella, parent,
predecessor, or otherwise "related" issue. Aiming a closing keyword at
another issue would auto-close that issue when this PR merges, which
is what the closing-keyword rule — PR body only, the branch's own
issue set only — exists to prevent.

That rule also settles what happens when the caller's numbers and the
branch name disagree, and applying it is not this skill's job:
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

1. **Resolve the set of issues to ensure.** Fetch the PR's head branch:

   ```text
   /github-prs:pr-view <PR> --json headRefName --jq .headRefName
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

2. **Ensure the lines** with the bundled script, spelled as a bare
   name, passing every member of `<issues>`:

   ```bash
   pr-link-issue <PR> <issueA> <issueB>
   ```

   The script reads the body and the issues it already closes. Members
   already closed are left alone; for the rest it keeps the existing
   body verbatim, appends one `Closes #<issue>` line per issue after a
   blank line, writes the body back, and re-reads it. When every member
   is already closed it writes nothing and prints
   `PR <PR> already closes <issues>`. Every issue it is given that the
   body does not close gets a line, so never pass an issue outside the
   branch's set, and never write the keyword into a commit message.

   | Exit | Meaning |
   | --- | --- |
   | 0 | the body closes every issue given; stdout names the ones already closed and the lines appended |
   | 1 | a command the script ran failed, such as a `gh` call; its own error is on stderr above the script's line |
   | 2 | a usage error; the body is untouched |
   | 3 | the re-read body is not the body written; stderr says so |

   On any non-zero exit, surface stderr verbatim in the report-back.

3. Report back a single line: which members were already linked and
   which had a `Closes #<issue>` line appended, as the script's stdout
   names them, naming `<PR>`, plus
   any caller-supplied number step 1 reported as sitting outside the
   branch's set. If step 1 gave no safe resolution, the body is
   unchanged — report that outcome instead, with both sets.
