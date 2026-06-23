# User-config reader contract (`skills/lib/user-config.md`)

This file is the single source of truth for how readers should
consume the two **user-config** files. It is **reference prose**,
not an executable script: a reader (orchestrator, subagent, or
skill) follows the patterns documented here when it loads a
user-config file. Individual readers reference this doc rather than
re-deriving the parse rules or abort wording.

The analogous libraries are `skills/lib/repo-config.md` (the
team-shared, full-rewrite repo config), `skills/lib/issue.md`
(`/issue-*` shared reference), and the `/github-setup:gh-create-app` skill (GitHub
App resolver). This file plays the same role for the user-config
files.

User-config is the **per-user** counterpart to repo-config:
repo-config records team-shared, committed, per-repo behavior;
user-config records a single user's private, never-committed
settings. The two never overlap — a value that the whole team
should share goes in repo-config; a value that is one user's own
(an identity binding, a personal default) goes in user-config.

## Two scopes, one schema, one filename

There are **two** user-config files. They share this schema, this
read contract, and the same filename (`user-config.md`), but live
at different paths and answer different scopes:

- **User-global** — `~/.claude/rules/user-config.md`. Machine-wide
  settings that apply to every repo this user works in on this
  machine. Written by `/global-user-config`. Because `~/.claude`
  is itself a git clone (the mirror of `global-claude-config`),
  this file is gitignored there so a user's private values never
  get committed or mirrored — see
  `rules/repo-is-claude-config-source.md`.
- **Repo-level (per-repo-per-user)** — `<repo-root>/.claude/rules/user-config.md`.
  One user's own settings for one repo on one machine, not shared
  with the team. Written by `/user-config`, which also adds the
  file to the repo's tracked `.gitignore` so no clone ever commits
  it. This is where #156's `identity-key` binding lives.

**The filename collision is deliberate but must never be
ambiguous in a reader.** When this library or any reader refers to
"the user-config file" it must always say which scope. The two
canonical phrasings are:

- "the user-global user-config" / "`~/.claude/rules/user-config.md`"
- "the repo-level user-config" / "`<repo-root>/.claude/rules/user-config.md`"

A reader that wants a value checks the **repo-level** file first,
then falls back to the **user-global** file (repo-level overrides
user-global), unless the reader's own contract says otherwise. See
"Resolution order across the two scopes" below.

## Multi-writer: merge, not full-rewrite

Unlike `repo-config.md` (which `/repo-config` owns end-to-end and
rewrites in full), each user-config file is **multi-writer**.
Different skills own different keys in the same file: the identity
skill (#156) owns `identity-key`; future skills own their own
keys. The writer skills (`/user-config`, `/global-user-config`)
therefore **merge** — they read every existing value, replace only
the keys they own in this run, and preserve every sibling key
written by another skill. A reader must tolerate keys it does not
recognize and never treat an unknown key as an error.

## Current schema version

```text
SCHEMA_VERSION = 1
```

`1` is the version readers should require as of this writing. A
reader pins the **minimum** version it knows how to consume in its
own code (see "Reader-side version pin" below) and aborts cleanly
when the target file is older. The writers
(`/global-user-config`, `/user-config`) stamp `1` into every file
they produce; see those skills' SKILL.md files.

Why a minimum rather than an exact match (same rationale as
`skills/lib/repo-config.md`):

- Schema bumps are **additive by construction** — a bump adds new
  keys or new option values without changing the meaning of
  existing keys. A reader written against version `N` can safely
  read a version `N+1` file: the keys it knows about still mean
  what they did, and keys it does not know about are ignored.
- Readers accept **anything ≥ their pinned version**. Equal
  versions are read as-is; newer versions are read as if they were
  the pinned version, with unknown keys skipped. A reader still
  declares which version it was written against, so older files
  trigger a clean "Schema-version stale" abort with a
  re-run-`/global-user-config`-or-`/user-config` fix hint.
- Every bump pairs with a writer update and a bump to this
  constant. A future breaking-change bump may revisit this policy;
  until then, newer-is-fine.

## What the file looks like

Each user-config file has two parts, in order:

1. A YAML front-matter block, delimited by `---` on the line above
   and the line below. Contains a `schema-version:` integer (first
   key, always) plus zero or more owned keys (see "Owned keys"
   below). A freshly-created file may carry only `schema-version`
   and no owned keys yet — that is valid; user-config files are
   forward-looking and start mostly empty.
2. A prose body documenting the file's own keys for humans reading
   it directly. The body is not part of the read contract.

The front-matter is the machine-readable surface. All owned keys
live there. Optional structured blocks (analogous to repo-config's
`github-project:` block) may appear in the body in a future schema
version; none are defined at version `1`.

## Owned keys

At schema-version `1` the only **defined** key beyond
`schema-version` is reserved for the first consumer:

- **`identity-key`** *(repo-level only)* — string. A machine-local
  binding from this repo to a GitHub App private-key identity, read
  by #156's identity resolver via this contract. Owned by the
  identity skill, not by `/user-config`'s built-in interview. Lives
  only in the **repo-level** user-config (it is a per-repo-per-user
  binding); it is not a user-global value. Until #156 lands this
  key is documented-but-unwritten — the schema reserves it so the
  read path exists before the writer does, which is the entire
  reason this issue is a dependency of #156.

Both writer skills also support arbitrary user-entered keys via an
"Other" interview branch, so a user can record a personal default
(`preferred-editor`, `default-reviewer`, etc.) without a schema
bump. Readers treat any key they do not recognize as opaque
pass-through and never error on it. A key is "owned" by whichever
skill writes it; the merge contract (above) keeps owners from
clobbering each other.

There are **no required owned keys**. A user-config file with only
`schema-version: 1` in its front-matter is valid and complete. This
is the key difference from repo-config, which requires all six
canonical fields — user-config has no canonical field beyond the
version stamp.

## Canonical read sequence

Every reader of a user-config file follows this sequence. Each
numbered step has a single canonical abort message (see "Abort
messages" below); use the wording verbatim so readers present
consistent errors. Substitute the correct scope name and path
(user-global vs repo-level) into each message.

1. **Locate the file.** For the **repo-level** file, find the repo
   root with `git rev-parse --show-toplevel`; the file lives at
   `<repo-root>/.claude/rules/user-config.md`. For the
   **user-global** file, the path is `~/.claude/rules/user-config.md`
   (expand `~` to the user's home directory). Do not assume the
   caller's cwd is the repo root.

2. **Read the file.** If the file is absent, the reader **degrades
   gracefully** — user-config files are optional. A reader that
   needs a specific key proceeds as if that key were unset (see
   "Graceful degradation" below). A reader only aborts on absence
   if its own contract declares the file mandatory; the default is
   degrade-not-abort.

3. **Parse the front-matter.** Find the opening `---` (the file's
   first non-blank line) and the closing `---`. Parse the lines
   between them as YAML. If the front-matter block is malformed or
   absent on a file that does exist, treat it as schema-version `0`
   and abort with the "Schema-version absent" message.

4. **Check `schema-version`.**
   - If the `schema-version` key is absent from the parsed
     front-matter, treat its value as `0` and abort with the
     "Schema-version absent" message.
   - If the parsed value is an integer less than the reader's
     required version, abort with the "Schema-version stale"
     message, naming both the file's version and the required
     version.
   - If the parsed value equals the reader's required version,
     proceed.
   - If the parsed value is **greater than** the reader's required
     version, proceed and read only the keys documented for the
     reader's version — newer schema versions are forward-compatible
     by construction (additive). Do not abort on a higher version.

5. **Read the keys the reader needs.** Pull only the owned keys the
   reader cares about. A missing **optional** key (every key is
   optional at version `1`) is not an error — the reader degrades
   per its own contract. Do not error on keys you do not recognize.

6. **Return resolved values.** Hand the parsed values back to the
   caller. Do not cache across runs — readers re-read the file
   every time so that a re-run of a writer skill between calls is
   picked up immediately.

### Resolution order across the two scopes

When a reader can sensibly look in either scope for the same key,
the order is **repo-level overrides user-global**:

1. Read the repo-level file (`<repo-root>/.claude/rules/user-config.md`).
   If it exists and defines the key, use that value.
2. Otherwise read the user-global file
   (`~/.claude/rules/user-config.md`). If it exists and defines the
   key, use that value.
3. Otherwise the key is unset — degrade per the reader's contract.

Some keys are scope-specific by definition and skip this fallback.
`identity-key` is **repo-level only**: a reader for it reads the
repo-level file and never falls back to user-global. The owned-key
table above marks scope-specific keys. When in doubt, a reader's
own contract states which scope(s) it consults.

### Reader-side version pin

A reader pins the **minimum** schema-version it requires as a
constant in its own code. For prose-defined readers (subagent
definitions, skill SKILL.md files), the constant is a literal in
the reader's text; for any future executable reader, it would be a
code constant.

The pinned value should equal the version this library documents
at the time the reader was written. Readers accept files at the
pinned version **or newer**; they abort with "Schema-version
stale" only when the file is at an *older* version. When the schema
bumps:

1. The writers (`/global-user-config`, `/user-config`) bump their
   emitted value.
2. This library bumps `SCHEMA_VERSION` to match.
3. Existing readers continue to work against newer files without
   modification, because bumps are additive by construction. A
   reader's pin is bumped only when it needs a newly-added key.

## Graceful degradation

User-config files are **optional** by design (forward-looking,
mostly-empty-to-start). The default reader behavior on
absence-or-missing-key is to **degrade, not abort**:

- **File absent**: proceed as if every owned key were unset. The
  reader uses its own fallback (a built-in default, a prompt, or a
  no-op), exactly as it would if the file existed but omitted the
  key.
- **File present, key absent**: same — the key is unset; use the
  fallback.
- **File present, key present**: use the value.

A reader only escalates absence to an abort when its own contract
declares the value mandatory. #156's `identity-key` reader, for
example, may treat a missing binding as a hard error with a
"run the identity skill" fix hint — but that decision belongs to
the #156 reader contract, not to this library. This library's
default is degrade.

The schema-version aborts (Steps 3–4) are the exception: a file
that *exists* but predates versioning or is stale is a real
misconfiguration the user must fix, so those abort rather than
degrade.

## Abort messages

Use these exact wordings so every reader emits the same error.
Variable parts are wrapped in backticks. `<path>` is the
scope-appropriate path (`~/.claude/rules/user-config.md` for
user-global, `<repo-root>/.claude/rules/user-config.md` for
repo-level). `<skill>` is the scope-appropriate writer
(`/global-user-config` for user-global, `/user-config` for
repo-level).

- **Schema-version absent**

  > `<path>` predates user-config schema versioning. Run `<skill>`
  > to migrate.

  Triggered when a file that exists has front-matter with no
  `schema-version:` key (or malformed/absent front-matter). Treated
  as schema-version `0`.

- **Schema-version stale**

  > `<path>` is at schema-version `<N>`; this reader requires
  > `<M>`. Run `<skill>` to migrate.

  Triggered when the parsed `schema-version` integer is less than
  the reader's required version. `<N>` is the file's current
  version, `<M>` is the reader's required version.

- **File missing** *(only when the reader's contract makes the file
  mandatory — not the default)*

  > `<path>` does not exist. Run `<skill>` to create it.

  Most readers do **not** use this message — they degrade per
  "Graceful degradation" above. A reader uses it only when its own
  contract declares the user-config file (or a specific key)
  mandatory, the way #156's identity reader treats a missing
  `identity-key`.

Readers should not invent additional abort messages for the same
failure shapes. If a new failure shape arises, document it here
rather than ad-hoc wording in the reader.

### Per-field accessor pattern

Readers that need a single key follow this shape (prose pseudocode;
the actual reader is whatever language fits):

```text
cfg = read_user_config(scope = "repo-level", required_version = 1)
key = cfg.get("identity-key")        # None if absent -> degrade
```

The read step does the schema-version check once; per-field
accessors are plain dictionary lookups on the resolved value. Do
not re-parse the file per key.

## Example consumer (proves the read path)

This is the minimal end-to-end consumer that demonstrates the read
contract works. It is intentionally low-touch: a documented reader
in prose plus the real reader wired in `skills/issue-create/SKILL.md`
(see "Optional: per-user assignee default" there).

A reader that wants a per-user default GitHub assignee — so a
single user can have their issues self-assigned without changing
the team-shared repo-config — follows the contract above:

```text
# Resolution order: repo-level overrides user-global.
cfg_repo   = read_user_config(scope = "repo-level",   required_version = 1)
cfg_global = read_user_config(scope = "user-global",  required_version = 1)

assignee = cfg_repo.get("default-assignee")
        or cfg_global.get("default-assignee")
        or <current GitHub user>     # built-in fallback (degrade)
```

`default-assignee` is an example owned key (owned by `/user-config`
/ `/global-user-config`'s "Other" interview branch). It is not a
required key; if neither file defines it, the reader degrades to
its existing built-in default. This proves the full path:
two-scope resolution, optional-key degradation, and a real
fallback — without mutating any heavily-used behavior.

## Conventions for readers

When writing or updating a reader of a user-config file:

- Open with a one-line statement of which schema-version the
  reader requires and which **scope(s)** it consults.
- Reference this file: "See `skills/lib/user-config.md` for the
  read contract, scope resolution, and abort messages."
- Do **not** restate the canonical abort wording inline — quote it
  from this file by exact wording, substituting the scope path and
  writer-skill name.
- Always name the scope explicitly (user-global vs repo-level) —
  the two files share a filename and a reader that is vague about
  scope is a bug.
- Default to **degrade, not abort** on absence. Only abort if the
  reader's own contract makes the value mandatory.
- Re-read the file every run. Do not cache parsed values across
  invocations; a re-run of a writer skill between two reads must
  be picked up.
