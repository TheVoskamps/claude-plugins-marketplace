---
name: pr-create
description: Open a draft GitHub PR for a branch against the configured base, with one closing keyword per issue in the branch's own issue set in the PR body.
---

# PR Create

Open a pull request for a feature branch as a **draft**, targeting the
base branch read from repo-config, with a closing keyword in the PR
body for each issue in the branch's OWN issue set. This is the
PR-create operation the `/sdlc:orchestrate` flow's `issue-developer`
previously performed as a raw `gh pr create`; the skill now owns it,
including the config read.

A branch carrying one issue is the k=1 case of the same shape: one
closing line, exactly as before.

This skill is **GitHub-only by design**. It is built directly on
`gh pr create`; there is no CodeCommit (or other source-control)
branch, and none is planned here — CodeCommit is deliberately out of
scope for this plugin.

## Invocation

```text
/pr-create <issue-number>… <branch>
```

- `<issue-number>…` (required): the issues this PR resolves — members
  of the branch's OWN issue set, each with or without a leading `#`,
  separated by spaces or commas. See "Own issue set only" below.
- `<branch>` (required): the head branch the PR is opened from,
  conventionally the one `git-tools:git-branch-create` produced for
  the issue set.

The `<branch>` argument is the last one, so the issue numbers are
whatever precedes it.

## Repo-config

This skill reads two values from `.claude/rules/repo-config.md`
**internally** — the caller does not pass them. It reads them with a
lightweight **inline** parse of just these two front-matter lines,
not the full reader contract in the `issues` plugin's
`skills/lib/repo-config.md`: that lib file lives inside the `issues`
plugin, and plugins are file-sandboxed (a bare `Read` from another
plugin's skill cannot resolve a path outside its own plugin directory
— see `docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). Bundling a duplicate copy of the 496-line lib into
this plugin, or inventing a cross-plugin `Read`, would either
reproduce the exact coupling issue #143 removed from `sdlc` or simply
not work; a two-field inline parse avoids both.

If `.claude/rules/repo-config.md` is missing, abort with: "This repo
has no `.claude/rules/repo-config.md`. Run `/repo-config` to create
one." (the same wording the full reader contract uses for its
"File missing" case, so the namespace's abort messages stay
consistent even though this skill doesn't consume the whole contract).

The values consumed:

- **`default-pr-target-branch`** — the base branch the PR targets.
- **`issue-link-prefix`** — the literal string concatenated with the
  issue number in the closing keyword (`#` on GitHub, so each line
  reads `Closes #<N>`).

Re-read the file every run; do not cache across invocations.

Nothing about the **branch name** is read here.
`git-tools:git-issues-from-branch`, which step 1 invokes, does its own
internal read of `issue-branch-naming-prefix`.

## Own issue set only

Every issue this PR closes MUST be a member of the branch's own issue
set — **never** an umbrella, parent, predecessor, or otherwise
"related" issue. Aiming a closing keyword at another issue would
auto-close that issue when this PR merges, which is what the
closing-keyword rule in `rules/git-workflow.md` — PR body only, the
branch's own issue set only — exists to prevent.

That rule also settles what happens when the caller's numbers and the
branch name disagree, and it is **global** rather than this skill's:
`rules/git-workflow.md` → "Issue References" is the authority, and
`/git-tools:git-issues-from-branch` is the one skill that applies it.

This skill's part is small. Its **claim** is the caller-supplied
numbers — a caller of `/pr-create` always has the issues in hand, so
there is nothing to look up. It hands that claim to
`/git-tools:git-issues-from-branch` alongside the branch, and acts on
what comes back. It never parses a branch name and never re-derives
the resolution.

## Execution

1. **Resolve the set of issues to close.** Invoke
   `/git-tools:git-issues-from-branch <branch> <issue-number>…` —
   the branch first, the caller-supplied numbers after it as the
   claim.

   - **A resolved set** is the set this PR closes. Call it `<N…>`.
   - **No safe resolution** — open no PR. Report that outcome with
     both sets exactly as the skill named them, and stop; the caller
     re-invokes with numbers drawn from the branch's set.

   Note the "claimed outside the branch set" numbers it reports: those
   get no closing line, and the refusal is named in the report-back
   rather than silently swallowed.

2. **Open the PR as a draft**, targeting the configured base, with one
   closing keyword line per member of `<N…>` in the body:

   ```bash
   gh pr create --draft --base <default-pr-target-branch> \
     --head <branch> \
     --title "<Imperative description>" \
     --body "## Summary
   <what changed and why>

   Closes <issue-link-prefix><N1>
   Closes <issue-link-prefix><N2>"
   ```

   - **One keyword per line, one line per issue.** GitHub links only a
     reference that carries its own keyword immediately before it, so
     `Closes #196, #201` links `#196` only and silently leaves `#201`
     unlinked. Repeating the keyword is what makes every member link
     and auto-close.
   - `--draft` is REQUIRED: every PR is born as a draft. A draft PR
     cannot be auto-merged (the repo's auto-merge workflow filters
     `isDraft == false`), so it stays inert until an
     orchestrator/human flips it ready. The closing keyword only fires
     on merge to the default branch, so it too stays inert while the
     PR is draft.
   - The closing lines belong in the **PR body**, never in a commit
     message — that is how the PR gets its Development-sidebar links
     AND how each issue auto-closes on merge. Never aim a closing
     keyword at an issue outside the branch's set, and never write one
     into a commit message.
   - If the caller supplies title/body text, use it; otherwise
     synthesize a concise imperative title and a short summary. Always
     ensure a `Closes <issue-link-prefix><N>` line is present for every
     member of `<N…>`.
   - When step 1 reported **branch members not claimed** — a member
     was dropped mid-flight — say so in the body: name the deferred
     issue and why it is not in this PR, so the reviewer and the human
     can tell a sanctioned deferral from a silent under-delivery.

3. Report back a single line: the PR URL, the branch, and the issue
   set `<N…>` the PR closes. Name any unclaimed branch member and any
   caller-supplied number refused for sitting outside the branch's
   set, as step 1 reported them. If step 1 gave no safe resolution,
   there is no PR — report that outcome instead, with both sets.
