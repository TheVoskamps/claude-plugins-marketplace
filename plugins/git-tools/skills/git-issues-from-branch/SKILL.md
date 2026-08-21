---
name: git-issues-from-branch
description: Recover the ordered issue set and slug an issue branch's name encodes (issue-<N1>-<N2>-...-<slug>), and optionally reconcile a caller's claimed issue list against it. The inverse of git-branch-create.
---

# Git Issues From Branch

Recover the issues a branch name carries — strip the configured naming
prefix, apply the branch-name grammar, and report the **ordered issue
set** plus the slug — or report that the branch does not follow the
convention at all. Handed a caller's **claimed** issue list as well,
reconcile the two and report the comparison.

This is the inverse of `git-tools:git-branch-create`, and the round
trip is the contract: given a branch that skill created, this one
returns the issue numbers it was given, in the order it was given
them, and the slug it used. A branch it did not create is the
**not-a-convention-branch** outcome below.

This skill is the only parser of branch names in this marketplace, and
the only place the issue-to-branch reconciliation rule is applied.
Consumers in other plugins — `github-prs:pr-create`,
`github-prs:pr-link-issue`, and `sdlc:theorem-based-pr-reviewer` —
invoke it
instead of restating either rule: skill invocation crosses the plugin
sandbox boundary that a `Read` cannot (see
`docs/plugin-authoring-constraints.md` → "Skill invocation
is global and namespaced"). Each of them keeps its own **action** per
outcome; none of them re-derives the outcome itself.

The skill parses strings. It runs no git command, so the branch need
not exist locally or on the remote.

## Invocation

```text
/git-tools:git-issues-from-branch <branch-name> [<claimed-issue>…]
```

- `<branch-name>` (required, first): the branch name to parse, with
  any `<initials>/` or `<name>/` prefix still attached — e.g. a PR's
  `headRefName`, or the branch a caller is about to open a PR from.
- `<claimed-issue>…` (optional): the issues the caller believes this
  branch delivers, each with or without a leading `#`, separated by
  spaces or commas. Every token after the branch name is one. Supply
  them to get the reconciliation in "Reconciling a claimed list"
  below; omit them and this skill parses the name and stops.

## Repo-config

This skill reads one value from `.claude/rules/repo-config.md`
**internally** — the caller does not pass it. It reads it with a
lightweight **inline** parse of just that front-matter line, not the
full reader contract in the `issues` plugin's
`skills/lib/repo-config.md`: that lib file lives inside the `issues`
plugin, and plugins are file-sandboxed (a bare `Read` from another
plugin's skill cannot resolve a path outside its own plugin directory
— see `docs/plugin-authoring-constraints.md` → "Plugins are
file-sandboxed"). It is the same inline read
`git-tools:git-branch-create` performs on the same field, which is
what keeps the two halves of the round trip agreeing.

If `.claude/rules/repo-config.md` is missing, abort with: "This repo
has no `.claude/rules/repo-config.md`. Run `/repo-config` to create
one." (the same wording the full reader contract uses for its
"File missing" case, so the namespace's abort messages stay
consistent even though this skill doesn't consume the whole contract).

The value consumed:

- **`issue-branch-naming-prefix`** — the prefix `git-branch-create`
  puts in front of the branch name, one of `none`, `initials`, or
  `name`. This skill strips it. It never needs the `<initials>` or
  `<name>` value itself, so it never asks for one.

Re-read the file every run; do not cache across invocations.

## The grammar

The branch-name grammar is stated **once**, in
`git-tools:git-branch-create` → "Branch name". Read that section
before parsing — it is a sibling skill in this same plugin, so the
path resolves:
`${CLAUDE_PLUGIN_ROOT}/skills/git-branch-create/SKILL.md`.

Do not restate or reimplement the rule here. A copy in this file would
be a second statement of the grammar, which is the thing this skill
exists to prevent.

## Reconciling a claimed list

How a PR's issues relate to its branch's name is a **global** rule,
not a per-caller convention. `rules/git-workflow.md` → "Issue
References" is its normative statement and this skill's authority for
everything below: the branch's set is a maximum rather than an
equality, a PR may close a subset of it and never a superset, and
where a caller's claim and the branch name disagree the branch name is
the higher-fidelity source of truth. This skill is where that rule is
*applied*, so no consumer re-derives it.

Call the branch's set `B` and the caller's claimed list `C`. Both are
compared as **sets**; the order either one arrives in carries no
meaning for the comparison (see "Order is a record, not a comparison
key" below). The outcomes:

- **Overlap** — the resolved set is the members present in both. The
  claim selects, the branch bounds.
- **No overlap, and `B` has one member** — the resolved set is `B`.
  The branch names exactly one issue, so standing it in for a claim
  that matched nothing guesses at nothing.
- **No overlap, and `B` has several members** — **no safe
  resolution**: report no resolved set. Standing the whole of `B` in
  would resolve to members the caller may have deliberately left out,
  which is the very subset the rule above exists to allow, and picking
  among them is a decision this skill does not have the information to
  make. The consumer decides what to do — see its own steps.
- **Not a convention branch** — there is no `B` to bound anything
  with, so the claim stands as-is: the resolved set is `C`, unchanged.

Alongside the resolved set, report these lists:

- **Claimed outside the branch set** — every member of `C` that is not
  in `B`. Computed against the claim **as passed**, so a one-member
  stand-in never hides one.
- **Branch members not claimed** — every member of `B` that the
  **resolved set** does not carry. Computed against the resolved set
  rather than against `C`, so the member a one-member stand-in
  resolved to does not also come back as unclaimed — it was resolved,
  which is the opposite. Where nothing resolved, that list is the
  whole of `B`.

Report them; do not act on them, and do not judge them. Whether an
unclaimed branch member is a sanctioned deferral or a silent
under-delivery, and what a claim outside the branch set warrants, are
consumer decisions. On the **not a convention branch** outcome there
is no `B` to compare against at all, so those lists come back empty.

## Execution

1. **Read `issue-branch-naming-prefix`** per "Repo-config" above.

2. **Strip the naming prefix** from `<branch-name>`:

   - `none` — there is nothing to strip.
   - `initials` or `name` — strip one leading `<segment>/`. The
     segment's content is not checked; this skill is not told the
     human owner's initials or name. A name with no `/` is passed
     through unchanged, so a branch created before the prefix was
     configured still parses.

3. **Apply the grammar** from "The grammar" above to what is left.
   The remainder must start with the `issue-` marker and carry at
   least one issue number after it; the grammar then fixes where the
   numbers stop and the slug starts.

4. **Decide the outcome.**

   - **Convention branch** — the remainder started with `issue-` and
     yielded at least one issue number. Report the numbers in the
     order the name carries them, plus the slug (which the grammar
     may leave empty).
   - **Not a convention branch** — anything else: a human-named
     branch, `dependabot/npm_and_yarn/…`, an `issue-` marker with no
     number after it, or a prefixed name under
     `issue-branch-naming-prefix: none` (stripping nothing is
     deliberate — under `none` the emitter writes no prefix, so a name
     carrying one did not come from it).

5. **Reconcile the claim, when one was supplied.** Strip each claimed
   token's leading `#` and any comma separators, then apply
   "Reconciling a claimed list" above to get the resolved set and the
   lists that go with it. With no claim supplied, skip this step
   entirely — the parse is the whole answer.

6. **Report** in the shape below. Report nothing else: this skill
   makes no decision about what the issues mean, and takes no action
   on them.

## Output

A convention branch, one line:

```text
issue-206-196-201-guardrails-gate-sweep: issues 206, 196, 201; slug guardrails-gate-sweep
```

A name the grammar leaves no slug on (`issue-206`) reports
`slug (none)`; the issue set is what the caller came for either way.

Not a convention branch, one line:

```text
dependabot/npm_and_yarn/undici-5.28.4: not a convention branch — no issue set
```

The second outcome is an **empty** issue set: there is no set to bound
anything with. A caller that supplied no claim falls back to whatever
it does when it has no branch set (see that caller's own steps); a
caller that supplied one gets its claim back unchanged, per
"Reconciling a claimed list" above.

### With a claimed list

Add a second line carrying the reconciliation. It always names the
resolved set (or the absence of one) and every list above, so a
consumer never has to infer one from the others:

```text
claimed 206, 196, 310 -> resolved 206, 196; claimed outside the branch set: 310; branch members not claimed: 201
```

The one-member stand-in and the no-safe-resolution outcome name
themselves:

```text
claimed 310 -> resolved 206 (one-member branch set stands in); claimed outside the branch set: 310; branch members not claimed: (none)
```

```text
claimed 310 -> no safe resolution, no claimed issue is in the multi-member branch set; claimed outside the branch set: 310; branch members not claimed: 206, 196, 201
```

On a branch the grammar rejects, the claim stands as-is and there is
nothing to compare it against:

```text
dependabot/npm_and_yarn/undici-5.28.4: not a convention branch — no issue set
claimed 310 -> resolved 310 (no branch set to bound the claim); claimed outside the branch set: (none); branch members not claimed: (none)
```

## Order is a record, not a comparison key

The reported order is the order the branch name carries, which is the
implementation order `git-branch-create`'s caller chose. The
reconciliation above compares as a **set**, never as a sequence, and
so does every consumer of what this skill reports, so the order is a
record for humans and never changes a decision. It is reported rather
than sorted so the round trip with `git-branch-create` is exact.
