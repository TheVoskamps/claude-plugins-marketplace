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

## The format is YAML, or Markdown when a human must read prose too

Two formats are in use, and neither is JSON:

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

## Multi-writer files merge; single-owner files rewrite

A file several skills write keys into is merged — read every existing
key, replace only the ones this run owns, preserve the siblings, and
never delete a key on a "leave unset" answer. A file one skill owns
end to end is rewritten whole. `user-config.md` is the first kind;
`repo-config.md` is the second. A reader of either tolerates keys it
does not recognize and never errors on one.
