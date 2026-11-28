---
name: claude-vm-config-global
description: Interactively create the global claude-vm config PAIR at ~/.config/claude-vm/config-bake.yml + config-boot.yml, interviewing from the launcher's own key table (claude-vm-config-keys) for each key's file and default. Idempotent — detects existing files and offers to merge or leave rather than clobber.
---

# claude-vm-config-global

You are running the `/claude-vm-config-global` skill. Your job is to
create the **global** claude-vm config **pair** at
`~/.config/claude-vm/config-bake.yml` and
`~/.config/claude-vm/config-boot.yml` (expand `~` to the user's home
directory).

This pair is the machine-wide layer of claude-vm's four-file config; the
per-repo pair at `<repo>/.claude-vm/config-{bake,boot}.yml`, written by
`/claude-vm-config-repo`, layers over it.

## The schema comes from the launcher

Run the key table and read the meanings before composing anything:

```bash
claude-vm-config-keys
```

It prints one key per line as the tab-separated fields key, file (`bake`,
`boot` or `both`), type, `list` or `scalar`, and default. It is the
launcher's own table, so it is the only source for which keys exist,
which file each goes in, and what each defaults to. Never write a key it
does not print.

Read `${CLAUDE_PLUGIN_ROOT}/skills/claude-vm/config-keys.md` for what
each key means, which values the launcher rejects, and how a key whose
file is `both` differs between the two files.

## Idempotent — detect and offer, never clobber

Before writing anything, check whether each of the two files already
exists:

- **Absent**: this is the create path for that file. Propose the full
  file, get approval, write it.
- **Present**: **do not clobber it.** Read it, show the user what is
  there, and offer:
  1. **Leave** the existing file untouched (the default, safe choice).
  2. **Merge** in the keys it is missing, preserving every key the user
     already set.

  A merge only fills gaps: it never overwrites or deletes a key the user
  set, and for a `list` key it unions new entries in without dropping the
  user's or duplicating any. If the file already has every key the
  interview produced, report that it is complete and leave it.

Writing either file requires explicit user approval in every case.

## Steps

Do not write a file until the user has explicitly approved its content.

### Step 1: Resolve the target paths

The config dir is `${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm`, matching
the launcher's `CLAUDE_VM_GLOBAL_CONFIG_DIR`. The targets are
`config-bake.yml` and `config-boot.yml` in it. The directory may not exist
yet; the `Write` tool creates it.

Also check for a **legacy** `config.yml` there. The launcher no longer
reads it and aborts on finding it, so offer to migrate its keys into the
pair, placing each by the key table's file column, and after writing the
pair remind the user to remove or rename the legacy file.

### Step 2: Detect existing files

Check each target independently, and on a present one ask (via
`AskUserQuestion`) whether to leave it or merge into it. On "leave", skip
that file.

### Step 3: Interview from the key table

Walk the rows of `claude-vm-config-keys`. A row whose file is `bake`
belongs to `config-bake.yml`, `boot` to `config-boot.yml`, and `both` to
either, with the meaning the file gives it.

- A **scalar with a default**: propose the default, and write the value
  the user settles on.
- A **scalar with no default**: write it only when the user gives a value.
  `claude.signing_key_fingerprint` is the exception to leaving it out: the
  launch aborts without it, so ask for it and walk the user through
  importing and verifying the key, as `config-keys.md` describes.
- A **list**: ask whether the user wants entries, and write entries only
  for what they name. `egress.allow` always carries `api.anthropic.com`;
  offer the other hosts `config-keys.md` gives for it.
- A **map** (`map(...)` type): write it only when the user names entries.

Ask about each feature area — packages, plugins, mounts, environment
variables, Remote Control — rather than every key one by one, and fold the
answers back onto the rows. For an `env.copy` entry, add its provider's
host to `egress.allow` in the same file, or write neither.

### Step 4: Compose the proposed content

Each file starts with a comment naming it as claude-vm's global bake or
boot config and stating that it holds no secrets, then the keys from Step
3 as YAML, nested by their dotted path. A key the interview left out is
absent from the file, not written as an empty placeholder: an empty
`claude.plugins` or `env` sub-key in the wrong file aborts the launch.

### Step 5: Show the proposed files and get approval

Render each full proposed file exactly as it will land on disk. For a
merge, also show which keys this run adds and which it preserves. Then
ask, per file:

> Write `~/.config/claude-vm/config-bake.yml` (and/or `config-boot.yml`)
> as shown? (y to proceed, or tell me what to change)

Wait for explicit approval, and re-render on any change.

### Step 6: Write, verify, and summarize

On approval, write each full file in one `Write` call. Then re-read it
and confirm it parses as YAML and holds the keys Step 3 produced, each in
the file its table row names.

Report back:

- The absolute path(s) written, or "left untouched" / "already complete".
- For a merge, which keys were added and which preserved.
- That the per-repo pair overrides scalars and unions lists, that editing
  a bake file rebuilds the image while editing a boot file does not, and
  that no secret is written here.

## Hard constraints

- **Idempotent.** Never clobber an existing config; offer leave (the
  default) or a gap-filling merge.
- **The key table decides placement and defaults.** Every key goes in the
  file its `claude-vm-config-keys` row names. Never write a key the table
  does not print.
- **`api.anthropic.com` stays in `egress.allow`.**
- **No secrets.** The host OAuth credential is mounted at launch, never
  written to config. A third-party API key goes in `env.copy` by name or
  `env.files` by path: never ask the user to paste a key, and never read
  one out of their environment to echo it back.
- **Never write without explicit approval** in Step 5.
- **Write exactly the two global files.** This skill touches no repo,
  edits no `.gitignore`, and runs no git commands.
