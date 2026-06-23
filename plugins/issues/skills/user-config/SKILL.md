---
name: user-config
description: Interactively create or merge-update the repo-level `.claude/rules/user-config.md` (this user, this repo, this machine) and add it to the repo's tracked `.gitignore`.
---

You are running the `/user-config` skill. Your job is to create or
**merge-update** the **repo-level** user-config file at
`<repo-root>/.claude/rules/user-config.md` by interviewing the user,
and to ensure that file is listed in the repo's tracked `.gitignore`
so no clone ever commits it.

This file records **one user's own settings for one repo on one
machine** — private, never committed, not shared with the team. It is
the per-repo-per-user counterpart to the team-shared, committed
`.claude/rules/repo-config.md`. See `skills/lib/user-config.md` for
the schema, the read contract, and the two-scope model. The
user-global counterpart (`~/.claude/rules/user-config.md`) is written
by the sibling skill `/global-user-config`.

## Merge, not full-rewrite — read this first

`/repo-config` is a **full-rewrite** tool: it owns its whole file and
replaces it every run. `/user-config` is **different**. The
user-config file is **multi-writer**: the identity skill (#156) owns
`identity-key`; other skills own other keys; this skill owns the keys
it interviews for. So `/user-config` **merges**:

1. Read the existing file's full front-matter into memory.
2. Replace only the keys this skill owns **and that the user changed
   in this run**.
3. **Preserve every other key verbatim**, including keys written by
   other skills and keys this skill does not recognize.
4. Re-stamp `schema-version` to the current version.

A rewrite-from-scratch would clobber sibling keys. Never do that. If
the file does not exist yet, "merge" degenerates to "create a new
file with just this run's keys plus the version stamp".

Follow the steps below in order. Do not write the file until the user
has explicitly approved the proposed content.

---

## Step 1: Pre-flight

Verify you are inside a git working tree:

```bash
git rev-parse --show-toplevel
```

If the command fails (non-zero exit, or stderr indicates "not a git
repository"), abort with:

> `/user-config` must be run from inside a git repository. The current
> directory is not a git working tree.

Treat the path printed by `git rev-parse --show-toplevel` as the
**repo root** for the rest of the skill — the skill writes
`<repo-root>/.claude/rules/user-config.md` regardless of which
subdirectory the user invoked from. Do **not** string-compare the
printed path against cwd (symlinks like macOS `/tmp` →
`/private/tmp` would mis-flag a legitimate repo root).

Also determine whether the user owns this repo (for the `.gitignore`
note in Step 5). Run `git remote get-url origin` and parse
`owner/repo`; compare `owner` against the current GitHub user
(`gh api user --jq .login`, if `gh` is available). This is advisory
only — used to phrase the `.gitignore` consequence note, not to gate
anything. If `gh` is unavailable, skip the comparison and use the
neutral phrasing in Step 5.

## Step 2: Detect existing config and read it for merge

Check whether `<repo-root>/.claude/rules/user-config.md` exists.

- **If it exists**: read the file's full contents into memory. Unlike
  `/repo-config`, you read it **to merge**, not just to display:
  parse the front-matter YAML so you can preserve sibling keys and
  pre-fill the interview with the user's current values as the
  recommended defaults.
  - Check `schema-version`. If it is absent or stale (less than the
    current version `1`), note that the merge will also migrate the
    stamp up. Do not abort — `/user-config` is the tool that fixes a
    stale stamp.
- **If it does not exist**: nothing to read. The interview's
  recommended values are this skill's built-in defaults, and the
  merge degenerates to a create.

The current schema-version constant baked into this writer is:

```text
SCHEMA_VERSION = 1
```

See `skills/lib/user-config.md` for the reader contract that consumes
it.

## Step 3: Interview

Use the `AskUserQuestion` tool. The repo-level user-config has **no
required keys** — at schema-version `1` every key is optional and the
file may legitimately contain only `schema-version`. The interview is
therefore an offer, not a gauntlet.

Ask the user which per-repo-per-user settings they want to record.
Present the keys this skill knows about, each with a "leave unset"
option, plus an "Other" branch for arbitrary keys:

1. **`identity-key`** — a machine-local binding from this repo to a
   GitHub App private-key identity (the binding #156's identity
   resolver reads). If the user wants to set it now, capture the
   string value. Recommended: **leave unset** unless the user is
   wiring up #156's identity flow — that flow normally writes this
   key itself. Surface a one-line note: "Usually written by the
   identity skill; set it here only if you know the key name."
2. **`default-assignee`** — an optional per-user GitHub login used by
   the example consumer documented in `skills/lib/user-config.md`
   (self-assign issues without touching team-shared repo-config).
   Recommended: leave unset.
3. **Other** — let the user add any `key: value` pair they want to
   record as a personal per-repo setting. Capture key and value as
   strings. Repeat until the user is done.

For each key:

- When the file already defined the key (Step 2), show the **current
  value** as the recommended option so the user can keep it.
- Otherwise recommend **leave unset**.
- Always allow free-text entry via "Other".

If the user picks "leave unset" for a key that **already exists** in
the file, do **not** delete it — leaving a key unset in the interview
means "do not change it", per merge semantics. To remove a key, the
user edits the file by hand or you offer an explicit "remove this
key" choice; default behavior never deletes a sibling.

If the user wants nothing recorded and the file does not yet exist,
confirm they still want a stub file (just `schema-version: 1`)
created so future skills have something to merge into. A stub is
valid and is the recommended outcome when the user is setting up the
repo ahead of #156.

## Step 4: Compute the merged front-matter

Build the front-matter that will be written by **merging**:

1. Start from the existing front-matter map parsed in Step 2 (empty
   map if the file did not exist).
2. For each key the user **changed or set** in Step 3, overwrite that
   key's value.
3. Leave every other existing key **untouched** (this is how sibling
   keys written by other skills survive).
4. Set `schema-version: 1` (re-stamp; first key in the rendered
   output).

Render order: `schema-version` first, then the remaining keys. For
keys that pre-existed, preserve their relative order; append
newly-added keys after the pre-existing ones. Quote any value that
YAML would otherwise misparse (e.g. a value starting with `#`).

## Step 5: Plan the `.gitignore` update

The repo-level user-config must never be committed. `/user-config`
ensures it is excluded via the repo's **tracked `.gitignore`** (not
`.git/info/exclude`): a committed `.gitignore` means *every* clone
and *every* teammate automatically ignores the file, so nobody
accidentally commits their own private copy.

Determine the entry to add. The path relative to repo root is:

```text
.claude/rules/user-config.md
```

Read the repo's existing `<repo-root>/.gitignore` (if any):

- **If the entry (or a pattern that already matches it) is present**:
  no `.gitignore` change is needed; note that in the Step 6 preview.
- **If absent**: plan to append the entry. Match the existing file's
  style — if the repo uses an allow-list / invert pattern (a leading
  `/*` that ignores everything, then `!`-negations), adding a plain
  ignore line still works because last-match-wins, but place it
  **after** any broad un-ignore of `.claude/` so it is not
  re-included. The relevant negation depth is whichever `!`-line
  un-ignores the directory that holds the file — in an allow-list
  repo that re-includes `.claude/rules/` (e.g.
  `!/.claude/rules/`), the new ignore line must sit **after** that
  `!/.claude/rules/` negation, not merely after a broader
  `!/.claude/`. When in doubt, append at the end of the file under a
  short comment:

  ```text
  # Per-repo-per-user config (private; never committed). Written by
  # /user-config. The entry is public in this tracked .gitignore even
  # though the file contents stay private.
  .claude/rules/user-config.md
  ```

**Consequence on record (surface this to the user):** the
`.gitignore` *entry* is public — it shows up in the repo's tracked
`.gitignore` and in any PR that adds it — even though the file
*contents* stay private and uncommitted. If the user does **not**
own this repo, note that adding the entry is a **tracked edit that
must go through a PR** to the repo's owners; the user may prefer to
use `.git/info/exclude` (per-clone, untracked) instead. Offer that
alternative when ownership detection in Step 1 suggests the user is
not the owner:

- **Owner / has push access**: recommend the tracked `.gitignore`
  edit (the default).
- **Not the owner**: ask whether to (a) add the tracked `.gitignore`
  entry anyway (will need a PR) or (b) add the pattern to
  `.git/info/exclude` instead (per-clone, no PR, but only protects
  this clone). Record the user's choice.

## Step 6: Show the proposed changes and wait for approval

Render, for the user to approve:

1. The **full merged file** exactly as it will appear on disk —
   front-matter (with `schema-version: 1` first and all preserved +
   changed keys) plus the canonical body template from Step 7. For an
   existing file, also show a short diff summary: which keys this run
   changes, which it preserves untouched.
2. The **`.gitignore` change** (the exact line to be appended, and to
   which file — tracked `.gitignore` or `.git/info/exclude` per the
   Step 5 choice), or "no `.gitignore` change needed" if already
   covered.

Then ask explicitly:

> Write `.claude/rules/user-config.md` (merged) and update the ignore
> list as shown? (y to proceed, or tell me what to change)

Wait for explicit approval (`y`, `yes`, `go`, `do it`, etc.). If the
user asks for changes, loop back to Step 3 or Step 5 as appropriate,
then re-render here.

## Step 7: Write the file and update the ignore list

On approval:

1. **Write the user-config file** with the `Write` tool, replacing
   the whole file with the merged content from Step 4 + the body
   template below. (You compute the full merged content in memory and
   write it in one call; the *content* is a merge even though the
   *write* replaces the file. Never use `Edit` to surgically rewrite
   one key — recompute the whole merged front-matter and write it,
   so the version stamp and key order stay consistent.)

   In a brand-new repo `.claude/` and `.claude/rules/` may not exist.
   The `Write` tool creates missing parents automatically. If your
   tool path does not, run `mkdir -p .claude/rules` first.

2. **Update the ignore list** per the Step 5 choice:
   - Tracked `.gitignore`: use `Edit` to append the planned entry (and
     its comment) to `<repo-root>/.gitignore`, or `Write` if the file
     does not exist yet. Do not reorder or rewrite unrelated lines.
   - `.git/info/exclude`: append the pattern to
     `<repo-root>/.git/info/exclude`. This is inside `.git/`, which
     is outside the worktree's tracked tree but still under the repo
     root — it is the deliberate per-clone alternative and is allowed
     here.
   - No change: skip.

Compose the user-config file in this order:

1. The merged YAML front-matter (`schema-version: 1` first, then
   preserved + changed keys).
2. A blank line.
3. The canonical body template (below), starting with
   `# User Config (repo-level)`.

The canonical body template:

````markdown
# User Config (repo-level)

Per-repo-per-user config: **this user, this repo, this machine.**
Private — never committed (the repo's `.gitignore` excludes it). Not
shared with the team. The team-shared, committed counterpart is
`.claude/rules/repo-config.md`; the user-global counterpart is
`~/.claude/rules/user-config.md`.

Read via the contract in `skills/lib/user-config.md`. Written and
merge-updated by `/user-config` (this scope) — the file is
**multi-writer**, so `/user-config` replaces only the keys it owns
and preserves keys written by other skills (e.g. `identity-key`,
written by #156's identity skill).

## Keys

- **schema-version**: integer naming the file's schema version.
  Current version is `1`. Writers stamp it; readers (see
  `skills/lib/user-config.md`) gate on it. Do not edit by hand.
- **identity-key** *(optional)*: machine-local binding from this repo
  to a GitHub App private-key identity, read by #156's identity
  resolver. Usually written by the identity skill, not by hand.
- *(other keys)*: any per-user, per-repo value future skills record.
  Unknown keys are preserved on merge and ignored by readers that do
  not consume them.

There are **no required keys** beyond `schema-version`. A file
containing only the version stamp is valid — these files are
forward-looking and start mostly empty.

## Why this file is gitignored, not committed

A value here is one user's own setting on one machine. Committing it
would leak a private binding (or impose one user's preference on the
team). `/user-config` adds this path to the repo's tracked
`.gitignore` so every clone ignores it automatically. The
`.gitignore` *entry* is public; the file *contents* are not.
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
  changed) is still present with its prior value — the merge
  preserved siblings.
- The canonical body template is present below the front-matter.

Also confirm the ignore-list change landed (the entry is present in
the chosen ignore file). If verification fails, surface the
discrepancy and stop — do not attempt a corrective second write.

## Step 8: Summarize

Report back:

- The absolute path written.
- Which keys were changed, which were preserved (merge summary), and
  the final `schema-version`.
- The ignore-list outcome: which file got the entry (tracked
  `.gitignore` or `.git/info/exclude`), or "already covered" /
  "no change".
- If the user is not the repo owner and chose the tracked
  `.gitignore`, remind them the entry will need a PR.

---

## Hard constraints

- **Merge, never full-rewrite.** Read existing keys, replace only the
  keys this run changes, preserve all siblings. Re-stamp
  `schema-version`. A rewrite-from-scratch that drops a sibling key
  is a bug.
- **Never delete a sibling key on a "leave unset" answer.** Leaving a
  key unset means "do not change it". Deletion requires an explicit
  user request.
- **Never write the file without explicit approval** in Step 6.
- **Never edit anything outside this repo.** The skill writes at most
  two files: `<repo-root>/.claude/rules/user-config.md` and the repo's
  ignore list (`<repo-root>/.gitignore` or
  `<repo-root>/.git/info/exclude`).
- **Never run destructive git commands.** This skill does not commit,
  push, branch, or reset. The user commits the `.gitignore` change
  themselves (the user-config file itself is ignored and never
  committed).
- **Surface the public-entry / private-contents consequence** and the
  not-the-owner PR caveat — do not silently add a tracked
  `.gitignore` entry in a repo the user does not own without saying
  so.
