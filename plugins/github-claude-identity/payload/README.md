# Template payload directory

This directory ships template files ("payloads") that the
`github-claude-identity` plugin's skill deploys per-machine to bootstrap
the Claude GitHub App identity. The one skill,
`gh-create-identity-app`, owns a subdirectory named after it; the skill
reads its templates from there at runtime.

The payloads ship with the plugin and live at
`${CLAUDE_PLUGIN_ROOT}/payload/<skill-name>/...` once installed. No
separate install step is required — they travel with the plugin.

## Directory layout

```text
payload/
  README.md                  # this file
  gh-create-identity-app/    # per-skill payload directory
    get-token.sh             # verbatim-deploy (no placeholders)
    credential-helper.sh     # verbatim-deploy (no placeholders)
    init-repo.sh             # verbatim-deploy (no placeholders)
    config.template          # rendered (has placeholders)
```

## Two kinds of payload: verbatim-deploy vs. rendered

Unlike `github-setup`, where every payload is a placeholder template,
this plugin's payloads split into two kinds:

- **Verbatim-deploy (no placeholders).** The three `.sh` files —
  `get-token.sh`, `credential-helper.sh`, and `init-repo.sh` — contain
  no `__PLACEHOLDER__` tokens. The skill copies them **byte-for-byte**
  into the un-mirrored per-machine directory
  (`~/.config/claude-github-app/`) and `chmod 700`s them. They read the
  rendered `config` at runtime; their behaviour is identical on every
  machine, so there is nothing to substitute.

- **Rendered (has placeholders).** Only `config.template` carries
  placeholders. The skill substitutes the App identifiers collected
  during the UI walkthrough, then writes the result to
  `~/.config/claude-github-app/config` (`chmod 600`). The rendered
  `config` is secret-bearing (it identifies your App install) and is
  **never** committed or mirrored — only the placeholder template
  ships.

## Placeholder syntax

Template files use **double-underscore delimited UPPER_SNAKE_CASE**
names as placeholders:

```text
__PLACEHOLDER_NAME__
```

`config.template` uses exactly these:

| Placeholder | Meaning |
| --- | --- |
| `__APP_ID__` | numeric GitHub App ID (from the App settings page) |
| `__INSTALLATION_ID__` | numeric installation ID (install URL ends `/installations/<id>`) |
| `__APP_SLUG__` | the App slug (from the App settings URL) |
| `__BOT_NAME__` | display name, conventionally `<slug>[bot]` |
| `__BOT_EMAIL__` | `<APP_ID>+<APP_SLUG>[bot]@users.noreply.github.com` |

The `__BOT_EMAIL__` format is load-bearing: this exact string earns
the `[bot]` commit badge **and** is the "is this an App repo?" signal
the naked-`gh` deny hook keys on. See `config.template`'s own comment
block.

## Discovering placeholders in a template

```bash
grep -oE '__[A-Z][A-Z0-9_]*__' <template-file> | sort -u
```

This returns the deduplicated list of placeholder names the template
expects. The skill resolves each one before rendering. The three `.sh`
files return nothing from this scan — that is what marks them
verbatim-deploy.

## Resolving placeholder values

For `config.template`, every placeholder is resolved from the App
identifiers the skill collects during the UI-gated registration
walkthrough (Steps 3–5 of `gh-create-identity-app`): the App ID, the
installation ID, and the App slug, from which the bot name and email
are derived.

A skill must never render a template with unresolved placeholders. If
any placeholder remains after the App identifiers are collected, the
skill aborts with:

> Unresolved placeholder `__NAME__` in template
> `<skill-name>/<file>`. Pass a value or add inference logic.

## Rendering a template

The render step is a simple string substitution:

1. Read `config.template` from
   `${CLAUDE_PLUGIN_ROOT}/payload/gh-create-identity-app/config.template`.
2. Strip the leading comment block.
3. For each placeholder, replace every occurrence of
   `__PLACEHOLDER_NAME__` with the resolved value.
4. Write the result to `~/.config/claude-github-app/config` and
   `chmod 600` it.

For the three verbatim-deploy `.sh` files there is no render step:
copy the file unchanged and `chmod 700` it.
