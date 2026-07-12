---
name: verify-tool-names-against-docs
description: When an issue asks to prune/validate agent tools: frontmatter, verify canonical tool names against live Claude Code docs rather than trusting the issue body's claims
metadata:
  type: feedback
---

When a fix touches an agent's `tools:` frontmatter list (adding, pruning,
or auditing tool names), fetch the current Claude Code
`tools-reference` and `sub-agents` docs (`https://code.claude.com/docs/en/tools-reference`,
`https://code.claude.com/docs/en/sub-agents`,
`https://code.claude.com/docs/en/plugins-reference`) and grep the
persisted WebFetch output for the exact tool names in question, rather
than relying on training-data priors about which tool names are valid.

**Why:** issue #120 asked to prune stale tool names (`LS`, `TodoRead`,
`TodoWrite`, `MultiEdit`) from the sdlc plugin's four agents. Verifying
against the live docs confirmed: `LS` was never a real tool (directory
listing goes through `Bash`/`ls`), `TodoRead` doesn't exist in the
current tool set at all, `TodoWrite` still exists but is disabled by
default in favor of `TaskCreate`/`TaskGet`/`TaskList`/`TaskUpdate`, and
`MultiEdit` is fully gone (its capability lives in `Edit` now). The
plugins-reference doc also gave the authoritative supported-front-matter-keys
list verbatim ("Plugin agents support `name`, `description`, `model`,
`effort`, `maxTurns`, `tools`, `disallowedTools`, `skills`, `memory`,
`background`, and `isolation`... `hooks`, `mcpServers`, and
`permissionMode` are not supported") which matched the issue's claim
exactly — good confirmation the issue was accurately scoped, not
something to take on faith.

**How to apply:** for any future sdlc-plugin issue touching agent
`tools:` lists or front-matter schema, re-verify against the docs
before editing — don't just trust the issue body's claimed stale-tool
list, since docs (and the plugin itself) can drift between when the
issue was filed and when it's picked up. In this run the plugin
version in the issue's Phase-1 analysis (0.3.0) was already stale by
the time of the fix (actual was 0.3.1) — another instance of "verify
the territory, not the map" for issue-body claims about current repo
state.
