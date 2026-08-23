---
name: git-branch-create
description: Create the correctly-named issue branch (issue-<N>-<slug>, or issue-<N1>-<N2>-...-<compound-slug> for a batch of issues) off the configured source branch, reading branch conventions from repo-config internally.
---

# Git Branch Create

Create the feature branch for an issue — or for a **batch** of issues
implemented together on one branch and delivered as one PR: resolve the
branch name from the issue numbers and the repo's branch-naming
convention, and create it rooted at the configured source branch. This
is the branch-create the `/sdlc:orchestrate` flow's `issue-developer`
previously performed as a raw `git switch -c`; the skill now owns it,
including the config read.

A batch of one is the ordinary single-issue case: it is the k=1
instance of the same shape, not a preserved special case, and it
produces exactly the `issue-<N>-<slug>` name it always did.

The inverse operation — recovering the issue set back out of a
finished branch name — is `git-tools:git-issues-from-branch`.

Rooting the branch at the **explicit** source branch is the
wrong-base guard: without an explicit start point, `git switch -c`
roots the new branch at whatever commit the worktree happened to be on,
not at the source branch's tip.

## Invocation

```text
/git-tools:git-branch-create <issue-number>… [<compound-slug>]
```

Arguments are parsed by the same rule that recovers the issue set from
a finished branch name (see "Branch name" below), applied after
stripping each token's leading `#` and any comma separators: the
**leading run of all-numeric tokens** is the issue set, and a single
remaining non-numeric token is the compound slug.

- `<issue-number>…` (required): one or more issue numbers in
  **implementation order** — dependency order within the batch — each
  with or without a leading `#`, separated by spaces or commas.
- `<compound-slug>` (optional for one issue, **required** for two or
  more): the kebab-case slug the branch name ends with. For a single
  issue the skill derives it from the issue title when none is
  supplied. For two or more, a mechanical merge of k titles produces
  garbage, so the caller supplies it — with two or more issues and no
  slug, **ask** rather than inventing one.

## Repo-config

This skill reads two values from `.issues/repo-config.md`
**internally** — the caller does not pass them. It reads them with a
lightweight **inline** parse of just these two front-matter lines,
not the full reader contract in the `issues` plugin's
`skills/lib/repo-config.md`: that lib file lives inside the `issues`
plugin, and plugins are file-sandboxed (a bare `Read` from another
plugin's skill cannot resolve a path outside its own plugin directory
— see `docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). Bundling a duplicate copy of that lib into this
plugin, or inventing a cross-plugin `Read`, would either
reproduce the exact coupling issue #143 removed from `sdlc` or simply
not work; a two-field inline parse avoids both.

If `.issues/repo-config.md` is missing, abort with: "This repo has
no `.issues/repo-config.md`. Run `/repo-config` to create one." (the
same wording the full reader contract uses for its "File missing"
case, so the namespace's abort messages stay consistent even though
this skill doesn't consume the whole contract).

The values consumed:

- **`default-issue-source-branch`** — the branch the new branch is
  rooted at (e.g. `main` or `integ`).
- **`issue-branch-naming-prefix`** — the prefix that goes in front of
  the branch name, one of `none`, `initials`, or `name`. See "Branch
  name" below for the shape each one produces.

  When the prefix is `initials` or `name`, the `<initials>`/`<name>`
  value comes from the human owner; if the invocation context does not
  supply it, ask before proceeding.

Re-read the file every run; do not cache across invocations.

## Branch name

```text
issue-<N1>-<N2>-…-<Nk>-<slug>
```

with the prefix `issue-branch-naming-prefix` asks for in front:

- `none`     -> `issue-<N1>-…-<Nk>-<slug>`
- `initials` -> `<initials>/issue-<N1>-…-<Nk>-<slug>`
- `name`     -> `<name>/issue-<N1>-…-<Nk>-<slug>`

At k=1 that is exactly the historical `issue-<N>-<slug>` (or
`<initials>/issue-<N>-<slug>` / `<name>/issue-<N>-<slug>`).

**Parsing rule.** After the `issue-` marker, the leading run of
all-numeric hyphen-separated tokens is the issue set; everything from
the first non-numeric token onward is the slug.

This section is the **only** statement of the branch-name grammar in
this marketplace — the "Invocation" section above applies it to argv
tokens and points back here rather than owning it. Nothing downstream
restates it either: `git-tools:git-issues-from-branch` is the one
parser — the inverse of this skill — and the consumers that need a
branch's issue set (`github-prs:pr-create` and
`github-prs:pr-link-issue`, to decide which issues a PR may close, and
`sdlc:theorem-based-pr-reviewer`, to decide which issues to review
against)
invoke that skill. The number/slug boundary must therefore stay
unambiguous, which is what the "no leading digit" validation below
protects.

**Order is implementation order**, not sorted: it records the order
the caller intends to work the issues, which for a batch carrying a
dependency edge is the order that edge forces. Every downstream
comparison against the recovered set is a **set** comparison, never a
sequence comparison, so the order is a record for humans and never
changes meaning.

## Validation

Check all of these before creating anything, and on failure abort with
an error naming the offending value:

- **A compound slug that begins with a digit.** `2-space-indent`
  against issue 206 would produce `issue-206-2-space-indent`, which
  the parsing rule reads as the set `{206, 2}` with slug
  `space-indent` — the intended set is unrecoverable. Ask for a slug
  starting with a lowercase letter.
- **A compound slug that is not kebab-case.** Lowercase letters,
  digits, and single hyphens only; it must start with a lowercase
  letter and must not start or end with a hyphen.
- **A branch name longer than 100 characters**, counting the
  `<initials>/` or `<name>/` prefix. Ask for a shorter compound slug.
- **Two or more issue numbers with no compound slug.** Ask for one;
  never merge the titles into a slug yourself.

## Execution

1. **Resolve the slug.**
   - Caller supplied one → validate it per "Validation" and use it
     verbatim.
   - Exactly one issue number and no slug → derive it from the issue
     title:

     ```bash
     gh issue view <N> --json title
     ```

     Lowercase, kebab-case, at most five words (e.g. `Orchestrator
     manages PR draft/ready state` ->
     `orchestrator-manages-pr-draft-ready`). A title-derived slug is
     subject to the same validation — a title starting with a number
     yields a leading-digit slug, so drop or spell out that leading
     token.
   - Two or more issue numbers and no slug → ask the caller for one
     and stop until you have it.

2. **Form the branch name** by joining the issue numbers in the order
   given, then the slug, behind the configured prefix, per "Branch
   name" above. Re-check the 100-character limit against the assembled
   name.

3. **Create the branch rooted at the configured source branch.**
   Fetch the source branch first, then switch onto the new branch with
   `origin/<default-issue-source-branch>` as the explicit start point.
   Use the defensive form so a leftover branch from a prior aborted run
   doesn't error the new run:

   ```bash
   git fetch origin <default-issue-source-branch>
   git switch -c <branch-name> origin/<default-issue-source-branch> \
      || git switch <branch-name>
   ```

4. Report back a single line: the branch name created, the issue set
   it encodes, and the source branch it was rooted at.
