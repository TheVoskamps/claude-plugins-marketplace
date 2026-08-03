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
auto-close that issue when this PR merges. Per the closing-keyword
rule in `rules/git-workflow.md` — PR body only, the branch's own issue
set only — when the caller-supplied numbers and the branch name
disagree, **the branch name is the higher-fidelity source of truth**.

Recover the branch's set by invoking
`/git-tools:git-issues-from-branch <branch>` — the inverse of the
skill that wrote the name, and the one parser of that grammar. This
skill never parses a branch name itself. Compare what it reports as a
**set**: the order it reports is the implementation order the caller
chose, and carries no meaning for this comparison.

**The branch's set is a maximum, not an equality.** A PR may close a
*subset* of it, never a superset. That is what lets a member be
dropped mid-flight — because it needed a design decision, or turned
out larger than scoped — without renaming a branch that already
carries commits. A closing line is therefore written only for an issue
that is in the branch's set; a caller-supplied number outside it never
gets one, and the refusal is named in the report-back rather than
silently swallowed.

The branch's set therefore *bounds* the caller rather than replacing
the caller's selection. It stands in for that selection only where
doing so cannot guess: a one-member branch set whose member the caller
missed. When nothing the caller passed is in a **multi-member** branch
set, this skill opens no PR at all — see step 1 below for the exact
resolution.

## Execution

1. **Resolve the set of issues to close.** Invoke
   `/git-tools:git-issues-from-branch <branch>` per "Own issue set
   only" and call what it reports `B`. Take the caller-supplied
   numbers as `C`. The set this PR closes is:

   - `C ∩ B` — the caller's selection, restricted to the branch's set.
   - `C ∩ B` empty and `|B| = 1` — use `B`. The branch name wins over
     a caller-supplied number that matches nothing: this is the
     single-issue mismatch case, and a one-member branch set leaves
     nothing to guess about which issue was meant.
   - `C ∩ B` empty and `|B| > 1` — **refuse**. Open no PR; report that
     no caller-supplied number is in the branch's set, naming both
     sets, and stop. Falling back to the whole of `B` here would write
     a closing line for every member — including any the caller
     deliberately dropped, undoing the mid-flight drop that "Own issue
     set only" above exists to allow. The caller re-invokes with
     numbers drawn from `B`.
   - The skill reports **not a convention branch** — `B` is empty, so
     there is no branch set to bound the caller with: use `C`.

   Call the result `<N…>`. Note every member of `C` that was refused
   because it is not in `B`.

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
   - When the PR closes a strict subset of `B` — a member was dropped
     mid-flight — say so in the body: name the deferred issue and why
     it is not in this PR, so the reviewer and the human can tell a
     sanctioned deferral from a silent under-delivery.

3. Report back a single line: the PR URL, the branch, and the issue
   set `<N…>` the PR closes. Note any deferred member of `B`, and any
   caller-supplied number refused for being outside `B`. If step 1
   refused outright, there is no PR — report that refusal instead,
   with both sets.
