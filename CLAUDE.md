# CLAUDE.md

## Bump the plugin version when you change a plugin

When a PR modifies any file under `plugins/<name>/`, it MUST also bump
that plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`,
in the same PR. The version bump is a separate, deliberate edit. A
plugin change without a version bump is incomplete.

## Add a README roster entry when you publish a plugin

When a PR adds a new plugin entry to `.claude-plugin/marketplace.json`,
it MUST also add a matching bullet to the top-level `README.md`
"Published plugins" list, in the same PR. Registering the plugin in
`marketplace.json` and writing its own `plugins/<name>/README.md` does
not update that roster — it is a separate, easy-to-miss doc surface.
Word the bullet like its neighbors: the plugin name in bold backticks,
an em-dash, and a one-line description (pull language from the plugin's
`plugin.json` `description` or its README's opening line).
