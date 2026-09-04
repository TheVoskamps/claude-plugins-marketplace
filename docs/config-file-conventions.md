# Config file conventions

A plugin that persists state outside the repo picks a path and a
format. Both are already decided here, and the decision is not
transferable from whatever the ecosystem around the file does: JSON is
what `settings.json` and `~/.claude.json` use, and copying it into a
plugin's own config is the mistake this file exists to prevent.

## The path is `$XDG_CONFIG_HOME/<plugin>/`

Every per-user config lives at
`${XDG_CONFIG_HOME:-$HOME/.config}/<plugin-name>/<file>`, with the
variable used when set and non-empty and `$HOME/.config` when unset or
empty. The directory is the **plugin's** name, so two plugins never
collide and a user can delete one plugin's state without reading the
others. Per-repo counterparts live at `<repo-root>/.<plugin>/`, which
is where `.issues/` and `.claude-vm/` come from.

A skill spells the fallback out once and refers to that spelling
elsewhere rather than restating it, because a second spelling is a
second thing to get wrong.

### The permission gate reads `$HOME/.config` literally

The `guardrails` permission gate carves tool-mediated reads and writes
under `$HOME/.config` out of its containment deny, driven by globs the
operator lists in `~/.config/guardrails/config.yml` — which is what
makes any of these files reachable at all on a machine whose
`~/.config` is a symlink into a dotfiles repo. Its carve-out root is
the `$HOME/.config` spelling and **nothing else**: it does not consult
`$XDG_CONFIG_HOME`, because deriving a security carve-out from an
environment variable would let whatever set that variable relocate it.

So on a machine that relocates `$XDG_CONFIG_HOME`, the config a plugin
writes is still at the path this document prescribes, and is still
correct — but it is unreachable from a tool-mediated read or write,
because no carve-out covers it. A reader that is not a tool call at all
— a script running inside a claude-vm guest, say — is unaffected. The
**Bash tool** is not one of those: the carve-out reaches the file-tool
track only, so a skill that reads its own config with `cat` or `grep` is
denied on every machine, carve-out or not. `Read` is the only spelling a
listing can reach, and it reaches it only for a path that machine's
operator actually listed — on an unconfigured machine the `Read` denies
too, and a skill has to survive that rather than assume the file is
readable. Surviving it never means writing: a denial reports nothing
about whether the file exists, so a reader that seeds a default when
the file is absent, or rewrites a watermark at the end of a run, does
neither when the read denies — it says the read was denied, proceeds on
in-memory defaults for that run alone, and leaves a file it could not
see untouched. See
[`plugins/guardrails/hooks/permission-gate/README.md`](../plugins/guardrails/hooks/permission-gate/README.md)
for the carve-out's schema and scope limits.

## The format is YAML, or Markdown when a human must read prose too

The formats in use, none of them JSON:

- **YAML** (`*.yml`) — the default. `~/.config/claude-vm/config-*.yml`
  and `~/.config/auto-mode-tools/facts.yml` are this shape. It is what
  a `bash` reader can parse and what the harness's own front-matter
  already trains a model to read.
- **Markdown with YAML front-matter** (`*.md`) — when the file also
  carries prose a reader needs: what wrote it, what editing a key does,
  which skill owns which key.
  `~/.config/issues/user-config.md` is this shape. The keys go in the
  front-matter and nothing but prose goes in the body — a reader parses
  the front-matter and never the body.

Pick Markdown when a human opening the file cold would otherwise
guess wrong about what a key does; pick YAML when the keys speak for
themselves. Both spell keys in `kebab-case`.

JSON is never the answer for a config this marketplace's own plugins
write. It cannot carry a comment, which is exactly what the prose in
either format above is for.

## Every config carries `schema-version`

The first front-matter or top-level key is `schema-version`, an
integer. A reader pins the minimum it understands as a literal in its
own text, and on encountering the file:

- **absent, or the file is malformed** — abort, naming the path;
- **lower than the pin** — abort, naming both versions;
- **equal** — proceed;
- **higher** — proceed, reading only the keys the reader's version
  documents. Newer versions are additive, so this is safe by
  construction.

Aborting rather than guessing is the point: these files are
hand-editable, and a reader that silently treats a broken file as
absent will overwrite the user's edit with a default.

Absence of the **file** is a separate question from a bad stamp, and
the reader's own contract decides it: a config whose keys have
defaults degrades to them, while a watermark or a facts file that
cannot be invented stops and says what to write.

**Named exception: a reader with no channel to abort into.** The
`guardrails` permission gate's `~/.config/guardrails/config.yml` (see
above) treats absent, unreadable, malformed and below-the-pin
identically, as two empty lists — today's behaviour, with nothing
reported anywhere. A `PreToolUse` hook cannot abort: failing the hook
over a broken config denies every tool call on the machine, which is
strictly worse than the behaviour the operator had before writing the
file. The rule above stands for every reader that can surface an abort
to a human, which is all of the others.

## Multi-writer files merge; single-owner files rewrite

A file several skills write keys into is merged — read every existing
key, replace only the ones this run owns, preserve the siblings, and
never delete a key on a "leave unset" answer. A file one skill owns
end to end is rewritten whole. `user-config.md` is the first kind;
`repo-config.md` is the second. A reader of either tolerates keys it
does not recognize and never errors on one.
