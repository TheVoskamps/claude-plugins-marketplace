---
name: pr-create
description: Open a draft GitHub PR for a branch against the configured base, with a closing keyword for the branch's own issue in the PR body.
---

# PR Create

Open a pull request for a feature branch as a **draft**, targeting the
base branch read from repo-config, with a closing keyword for the
branch's OWN issue in the PR body. This is the PR-create operation the
`/sdlc:orchestrate` flow's `issue-developer` previously performed as a
raw `gh pr create`; the skill now owns it, including the config read.

This skill is **GitHub-only by design**. It is built directly on
`gh pr create`; there is no CodeCommit (or other source-control)
branch, and none is planned here — CodeCommit is deliberately out of
scope for this plugin.

## Invocation

```text
/pr-create <issue-number> <branch>
```

- `<issue-number>` (required): the issue this branch resolves — the
  branch's OWN issue, with or without a leading `#`. See "Own issue
  only" below.
- `<branch>` (required): the head branch the PR is opened from,
  conventionally `issue-<N>-<slug>` (or `<initials>/…` / `<name>/…`).

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
  issue number in the closing keyword (`#` on GitHub, so the body
  reads `Closes #<N>`).

Re-read the file every run; do not cache across invocations.

## Own issue only

`<issue-number>` MUST be the branch's own issue — the single issue the
PR resolves — **never** an umbrella, parent, predecessor, or otherwise
"related" issue. Aiming a closing keyword at another issue would
auto-close that issue when this PR merges. Per the git-workflow rule
("CRITICAL — closing keyword: PR body only, own issue only"), when the
caller-supplied number and the branch name disagree, **the branch name
is the higher-fidelity source of truth**: the branch-naming convention
is `issue-<N>-<slug>`, so `<N>` from `<branch>` is the authoritative
issue. Prefer the branch's `<N>` and note the discrepancy in the
report-back.

## Execution

1. **Resolve the authoritative issue number.** If `<branch>` matches
   `issue-<N>-<slug>` (with or without an `<initials>/` or `<name>/`
   prefix), use its `<N>`; otherwise use the passed `<issue-number>`.
   Call the result `<N>`.

2. **Open the PR as a draft**, targeting the configured base, with a
   closing keyword for `<N>` in the body:

   ```bash
   gh pr create --draft --base <default-pr-target-branch> \
     --head <branch> \
     --title "<Imperative description>" \
     --body "## Summary
   <what changed and why>

   Closes <issue-link-prefix><N>"
   ```

   - `--draft` is REQUIRED: every PR is born as a draft. A draft PR
     cannot be auto-merged (the repo's auto-merge workflow filters
     `isDraft == false`), so it stays inert until an
     orchestrator/human flips it ready. The closing keyword only fires
     on merge to the default branch, so it too stays inert while the
     PR is draft.
   - `Closes <issue-link-prefix><N>` in the **PR body** (never a commit
     message) is REQUIRED, not forbidden — it is how the PR gets its
     Development-sidebar link AND how the issue auto-closes on merge.
     Never aim the closing keyword at any other issue, and never write
     it into a commit message.
   - If the caller supplies title/body text, use it; otherwise
     synthesize a concise imperative title and a short summary. Always
     ensure the `Closes <issue-link-prefix><N>` line is present in the
     body.

3. Report back a single line: the PR URL, the branch, and the issue
   number `<N>` the PR closes. If the resolved `<N>` differed from the
   passed `<issue-number>`, note the discrepancy.
