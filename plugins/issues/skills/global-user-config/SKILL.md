---
name: global-user-config
description: Interactively create or merge-update the user-global `~/.claude/rules/user-config.md` (machine-wide; all repos on this machine).
---

You are running the `/global-user-config` skill. Your job is to create
or **merge-update** the **user-global** user-config file at
`~/.claude/rules/user-config.md` by interviewing the user.

This file records **machine-wide per-user settings** that apply to
every repo this user works in on this machine. It is the user-global
counterpart to the repo-level `.claude/rules/user-config.md` written
by the sibling skill `/user-config`. See `skills/lib/user-config.md`
for the shared schema, the read contract, and the two-scope model.

## Scope and the filename collision — read this first

Both user-config files are named `user-config.md`. This skill writes
**only** the user-global one at `~/.claude/rules/user-config.md`
(expand `~` to the user's home directory). It never touches a
repo-level `<repo-root>/.claude/rules/user-config.md` — that is
`/user-config`'s job. Be unambiguous about scope at every step.

`identity-key` is **repo-level only** (a per-repo-per-user binding),
so this user-global skill does **not** interview for it. Keys here are
machine-wide defaults that make sense across all repos.

## Merge, not full-rewrite — read this too

`/repo-config` is full-rewrite. `/global-user-config` is **merge**,
exactly like `/user-config`, because the user-global file is also
**multi-writer**: different skills own different keys. So this skill:

1. Reads the existing file's full front-matter into memory.
2. Replaces only the keys it owns **and that the user changed in this
   run**.
3. **Preserves every other key verbatim**, including keys this skill
   does not recognize.
4. Re-stamps `schema-version` to the current version.

If the file does not exist yet, "merge" degenerates to "create a new
file with this run's keys plus the version stamp".

Follow the steps below in order. Do not write the file until the user
has explicitly approved the proposed content.

---

## Step 1: Pre-flight

This skill writes to the user's home directory, not a repo, so there
is no git-working-tree precondition. Resolve the target path by
expanding `~`:

```text
~/.claude/rules/user-config.md
```

The directory `~/.claude/rules/` normally exists (it holds the
deployed global rules). If it does not, the `Write` tool will create
it.

> Note on the mirror clone: `~/.claude` is itself a git clone (the
> deployed mirror of `global-claude-config`). This file is gitignored
> there — see `rules/repo-is-claude-config-source.md` — so a user's
> private values never get committed back to the mirror. This skill
> does **not** add the `.gitignore` entry; that entry ships with the
> mirror's `.gitignore` as a deploy-time artifact. This skill only
> writes the user's values into the (already-ignored) file.

## Step 2: Detect existing config and read it for merge

Check whether `~/.claude/rules/user-config.md` exists.

- **If it exists**: read its full contents and parse the front-matter
  YAML so you can preserve sibling keys and pre-fill the interview
  with current values as recommended defaults.
  - Check `schema-version`. If absent or stale (less than current
    version `1`), note the merge will migrate the stamp up. Do not
    abort — this skill is the tool that fixes a stale user-global
    stamp.
- **If it does not exist**: nothing to read; recommended values are
  this skill's built-in defaults and the merge degenerates to a
  create.

The current schema-version constant baked into this writer is:

```text
SCHEMA_VERSION = 1
```

See `skills/lib/user-config.md` for the reader contract.

## Step 3: Interview

Use `AskUserQuestion`. The user-global user-config has **no required
keys** — at schema-version `1` every key is optional and the file may
contain only `schema-version`. The interview is an offer, not a
gauntlet.

Ask which machine-wide per-user settings to record. Present the keys
this skill knows about, each with a "leave unset" option, plus an
"Other" branch:

1. **`default-assignee`** — an optional GitHub login used as a
   machine-wide self-assign default by the example consumer in
   `skills/lib/user-config.md`. Recommended: leave unset.
2. **Other** — any `key: value` pair the user wants as a machine-wide
   personal setting (`preferred-editor`, `default-reviewer`, etc.).
   Capture key and value as strings. Repeat until done.

This skill does **not** offer `identity-key` — that is repo-level
only (use `/user-config`).

For each key:

- If the file already defined it (Step 2), show the **current value**
  as the recommended option so the user can keep it.
- Otherwise recommend **leave unset**.
- Always allow free-text via "Other".

A "leave unset" answer for a key that **already exists** means "do
not change it" — never delete a sibling on "leave unset". Deletion
requires an explicit user request.

If the user wants nothing recorded and the file does not exist,
confirm they still want a stub (`schema-version: 1` only) so future
skills have something to merge into. A stub is valid.

## Step 4: Compute the merged front-matter

Merge the same way `/user-config` does:

1. Start from the existing front-matter map (empty if no file).
2. Overwrite each key the user changed/set in Step 3.
3. Leave every other existing key untouched (sibling preservation).
4. Set `schema-version: 1` (first key in output).

Render order: `schema-version` first, then remaining keys —
pre-existing keys keep their relative order, newly-added keys append
after. Quote any value YAML would misparse.

## Step 5: Show the proposed file and wait for approval

Render the **full merged file** exactly as it will appear on disk:
front-matter (`schema-version: 1` first, all preserved + changed
keys) plus the canonical body template from Step 6. For an existing
file, also show a short diff summary: which keys this run changes,
which it preserves untouched.

Then ask explicitly:

> Write `~/.claude/rules/user-config.md` (merged) as shown? (y to
> proceed, or tell me what to change)

Wait for explicit approval. If the user asks for changes, loop back
to Step 3, then re-render here.

## Step 6: Write the file

On approval, use the `Write` tool to write the full merged content
(front-matter from Step 4 + body template below) in one call. The
*content* is a merge even though the *write* replaces the file; never
use `Edit` to surgically rewrite one key — recompute the whole merged
front-matter so the version stamp and key order stay consistent.

Compose in this order:

1. The merged YAML front-matter (`schema-version: 1` first, then
   preserved + changed keys).
2. A blank line.
3. The canonical body template (below), starting with
   `# User Config (user-global)`.

The canonical body template:

````markdown
# User Config (user-global)

Machine-wide per-user config: **this user, all repos, this machine.**
Private — never committed. Lives inside the `~/.claude` mirror clone
but is gitignored there (see `rules/repo-is-claude-config-source.md`)
so values never get committed or mirrored. The per-repo-per-user
counterpart is `<repo-root>/.claude/rules/user-config.md`
(written by `/user-config`).

Read via the contract in `skills/lib/user-config.md`. Written and
merge-updated by `/global-user-config` — the file is
**multi-writer**, so the skill replaces only the keys it owns and
preserves keys written by other skills.

## Keys

- **schema-version**: integer naming the file's schema version.
  Current version is `1`. Writers stamp it; readers (see
  `skills/lib/user-config.md`) gate on it. Do not edit by hand.
- *(other keys)*: any machine-wide per-user value future skills
  record. Unknown keys are preserved on merge and ignored by readers
  that do not consume them.

There are **no required keys** beyond `schema-version`. A file
containing only the version stamp is valid — these files are
forward-looking and start mostly empty.

`identity-key` does **not** live here — it is a per-repo-per-user
binding and lives only in the repo-level user-config.

## Resolution against the repo-level file

Readers that consult both scopes use **repo-level overrides
user-global** (see `skills/lib/user-config.md`). A value here is the
machine-wide default; a repo-level user-config can override it for
one repo.
````

### Verification

After the `Write` call, re-read the file and confirm the points
below. This re-read is **content verification, not write
verification**: `Write` already errors if the bytes did not land, so
the goal here is to confirm the merge produced the *intended
content* — schema-version stamped, owned keys updated, siblings
preserved — which a successful `Write` alone does not guarantee.
Keep this step even though it looks redundant with `Write` success.

- The front-matter parses as YAML, with `schema-version: 1` first.
- Every key that existed before the run (and was not intentionally
  changed) is still present with its prior value.
- The canonical body template is present below the front-matter.

If verification fails, surface the discrepancy and stop — do not
attempt a corrective second write.

## Step 7: Summarize

Report back:

- The absolute path written (`~/.claude/rules/user-config.md`,
  expanded).
- Which keys were changed, which were preserved (merge summary), and
  the final `schema-version`.
- A reminder that this file is the **user-global** scope and is
  gitignored in the mirror clone, so it is never committed.

---

## Hard constraints

- **Merge, never full-rewrite.** Read existing keys, replace only the
  keys this run changes, preserve all siblings. Re-stamp
  `schema-version`.
- **Never delete a sibling key on a "leave unset" answer.**
- **Never offer or write `identity-key`** — that is repo-level only.
  Direct the user to `/user-config` for it.
- **Never write the file without explicit approval** in Step 5.
- **Write exactly one file**: `~/.claude/rules/user-config.md`. This
  skill does not touch any repo, does not edit `.gitignore` (the
  mirror's `.gitignore` entry is a deploy-time artifact, not this
  skill's job), and does not run git commands.
