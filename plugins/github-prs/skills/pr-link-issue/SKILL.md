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
keyword (`close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/
`resolves`/`resolved`, case-insensitive) immediately followed by
`#<issue>` in the **PR description** does two things at once: it
creates the Development-sidebar "linked pull request" **and**
auto-closes the linked issue when the PR merges into the default
branch. A keyword in a *commit message* auto-closes but does **not**
create the sidebar link, which is why this skill writes the PR body,
never a commit. Both effects are intended: the sidebar link is the
whole point, and auto-close-on-merge is the behavior we want.

Each issue needs **its own keyword**. GitHub links only a reference
that carries a keyword immediately before it, so `Closes #196, #201`
links `#196` and silently leaves `#201` unlinked. This skill therefore
writes one `Closes #<issue>` line per issue.

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
another issue would auto-close that issue when this PR merges. Per the
closing-keyword rule in `rules/git-workflow.md` — PR body only, the
branch's own issue set only — when the caller-supplied numbers and the
branch name disagree, **the branch name is the higher-fidelity source
of truth**.

Recover the branch's set from its name by the parsing rule
`git-tools:git-branch-create` writes it with: after the `issue-`
marker, the leading run of all-numeric hyphen-separated tokens is the
set, and everything from the first non-numeric token onward is the
slug. So `issue-206-196-201-guardrails-gate-sweep` yields
`{206, 196, 201}`. Compare as a **set** — the order in the branch name
is implementation order and carries no meaning here.

**The branch's set is a maximum, not an equality.** A PR may close a
subset of it, never a superset: a member dropped mid-flight is not
closed by this PR, and re-adding its closing line here would undo that
deferral. So the caller's numbers select *which* members to ensure,
and the branch's set bounds *which are allowed*.

## Execution

1. **Resolve the set of issues to ensure.** Fetch the PR's head branch
   and body:

   ```bash
   gh pr view <PR> --json number,headRefName,body
   ```

   Recover the branch's set `B` from `headRefName` per "Own issue set
   only". Take the caller-supplied numbers as `C`. The set to ensure
   is:

   - `C ∩ B` — the caller's selection, restricted to the branch's set.
   - If `C ∩ B` is empty, or `B` could not be recovered because the
     head branch doesn't match the convention, fall back: use `B` when
     it is non-empty (the branch name wins over a caller-supplied
     number that matches nothing — the single-issue mismatch case),
     otherwise use `C`.

   Call the result `<issues>`. Note every member of `C` refused for
   being outside `B`.

2. **Idempotent check, per member.** For each issue in `<issues>`,
   scan the PR body for a closing keyword (`close`/`closes`/`closed`/
   `fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`,
   case-insensitive) immediately followed by a reference to that issue
   — i.e. the keyword, optional whitespace, then `#<issue>` (or
   `owner/repo#<issue>`, `GH-<issue>`, or the issue URL). The
   reference must resolve to that issue exactly; a keyword aimed at a
   *different* issue number does not satisfy the check for this one.

   - **Every member already linked** → no-op. Report `PR #<PR> already
     closes <issues>` and stop. Do not append a duplicate keyword.

3. **Append the missing ones.** Append one `Closes #<issue>` line for
   each member that failed the check in step 2 — and only those — to
   the existing PR body (preserve the current body; add the lines
   separated from it by a blank line) and write it back:

   ```bash
   gh pr edit <PR> --body "<existing-body>

   Closes #<issueA>
   Closes #<issueB>"
   ```

   Preserve the existing body verbatim; only add the missing closing
   lines. Never add a closing keyword aimed at an issue outside `B`,
   and never write the keyword into a commit message.

4. Report back a single line: which members were already linked and
   which had a `Closes #<issue>` line appended, naming `<PR>`, plus
   any caller-supplied number refused for being outside `B`.
