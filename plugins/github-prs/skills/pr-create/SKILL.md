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

This skill is **GitHub-only by design**. Its script opens the PR
through `gh`; there is no CodeCommit (or other source-control)
branch, and none is planned here — CodeCommit is deliberately out of
scope for this plugin.

## Invocation

```text
/pr-create <issue-number>… <branch>
```

- `<issue-number>…` (required): the issues this PR resolves — members
  of the branch's OWN issue set, each as `N` or `#N`, space-separated.
  See "Own issue set only" below.
- `<branch>` (required): the head branch the PR is opened from,
  conventionally the one `git-tools:git-branch-create` produced for
  the issue set.

The `<branch>` argument is the last one, so the issue numbers are
whatever precedes it.

## Repo-config

This skill's script reads two values from `.issues/repo-config.md`
**internally** — neither the caller nor this skill passes them. It
reads them with a lightweight **inline** parse of just these two
front-matter lines,
not the full reader contract in the `issues` plugin's
`skills/lib/repo-config.md`: that lib file lives inside the `issues`
plugin, and plugins are file-sandboxed (a bare `Read` from another
plugin's skill cannot resolve a path outside its own plugin
directory). Bundling a duplicate copy of that lib into this
plugin, or inventing a cross-plugin `Read`, would either
reproduce the exact coupling issue #143 removed from `sdlc` or simply
not work; a two-field inline parse avoids both.

If `.issues/repo-config.md` is missing, the script aborts with exit 4
and the wording the full reader contract uses for its "File missing"
case, pointing at `/repo-config`, so the namespace's abort messages
stay consistent even though this skill doesn't consume the whole
contract.

The values consumed:

- **`default-pr-target-branch`** — the base branch the PR targets.
- **`issue-link-prefix`** — the literal string concatenated with the
  issue number in the closing keyword (`#` on GitHub, so each line
  reads `Closes #<N>`).

The script re-reads the file on every run.

Nothing about the **branch name** is read here.

## Own issue set only

Every issue this PR closes MUST be a member of the branch's own issue
set — **never** an umbrella, parent, predecessor, or otherwise
"related" issue. Aiming a closing keyword at another issue would
auto-close that issue when this PR merges, which is what the
closing-keyword rule — PR body only, the branch's own issue set only —
exists to prevent.

That rule also settles what happens when the caller's numbers and the
branch name disagree, and applying it is not this skill's job:
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

2. **Write the body's summary to a file** under
   `.claude/tmp/<task-slug>/`, where `<task-slug>` is your own scratch
   slug, with the Write tool. If the caller supplies title/body text,
   use it; otherwise synthesize a concise imperative title and a short
   `## Summary` of what changed and why. Leave the closing lines out of
   the file — the script writes them.

   When step 1 reported **branch members not claimed** — a member was
   dropped mid-flight — say so in the summary: name the deferred issue
   and why it is not in this PR, so the reviewer and the human can tell
   a sanctioned deferral from a silent under-delivery.

3. **Open the PR as a draft** with the bundled script, spelled as a
   bare name, passing every member of `<N…>`:

   ```bash
   pr-create --head <branch> --title "<Imperative description>" \
     --body-file .claude/tmp/<task-slug>/pr-body.md <N1> <N2>
   ```

   The script opens the PR as a draft against
   `default-pr-target-branch`, with the file's text followed by a blank
   line and one `Closes <issue-link-prefix><N>` line per issue, then
   re-reads the PR and checks it is a draft on that base and head
   carrying that body.

   - **One keyword per line, one line per issue.** GitHub links only a
     reference that carries its own keyword immediately before it, so
     `Closes #196, #201` links `#196` only and silently leaves `#201`
     unlinked. Repeating the keyword is what makes every member link
     and auto-close.
   - **Every PR is born as a draft.** A draft PR cannot be auto-merged
     (the repo's auto-merge workflow filters `isDraft == false`), so it
     stays inert until an orchestrator/human flips it ready. The
     closing keyword only fires on merge to the default branch, so it
     too stays inert while the PR is draft.
   - The closing lines belong in the **PR body**, never in a commit
     message — that is how the PR gets its Development-sidebar links
     AND how each issue auto-closes on merge. Never aim a closing
     keyword at an issue outside the branch's set, and never write one
     into a commit message.

   | Exit | Meaning |
   | --- | --- |
   | 0 | the draft PR is open with the body written; stdout is its URL |
   | 1 | a command the script ran failed, such as the `gh` call; its own error is on stderr above the script's line |
   | 2 | a usage error; no PR was opened |
   | 3 | the PR did not land as asked — not a draft, the wrong base or head, or a different body — or `gh pr create` succeeded but printed no URL naming a PR number, so nothing was re-read and a PR may exist all the same; stderr names which |
   | 4 | `.issues/repo-config.md` is missing or lacks one of the two keys |

   On any non-zero exit, surface stderr verbatim in the report-back.

4. Report back a single line: the PR URL, the branch, and the issue
   set `<N…>` the PR closes. Name any unclaimed branch member and any
   caller-supplied number refused for sitting outside the branch's
   set, as step 1 reported them. If step 1 gave no safe resolution,
   there is no PR — report that outcome instead, with both sets.
