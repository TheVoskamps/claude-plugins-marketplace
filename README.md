# global-claude-plugins-marketplace

A [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces)
for The Voskamps' Claude Code plugins.

## Published plugins

The marketplace currently ships these plugins (one entry each in
`.claude-plugin/marketplace.json`):

- **`issues`** — GitHub issue tracking verbs and repo/user config.
- **`issues-jira`** — optional Jira backend for the issue verbs.
- **`sdlc`** — issue orchestration and the developer/fixer/reviewer/doc
  agents.
- **`github-setup`** — GitHub repo provisioning (App identity, PR
  automation, branch protection, public mirror, history scrubbing,
  private-to-public promotion).
- **`git-tools`** — branch/worktree cleanup and test generation.
- **`cc-tools`** — Claude Code maintenance helpers.
- **`github-claude-identity`** — run git + gh against GitHub as Claude's
  own bot identity (a dedicated GitHub App account) distinct from the
  user's personal identity. Bundles `gh_wrapper`, `git_wrapper`, and the
  `gh-create-identity-app` provisioning skill.
- **`guardrails`** — compiled PreToolUse permission-gate hook: command
  classification and worktree/cross-repo path containment,
  ask-defaulting and fail-closed.
- **`claude-vm`** — run Claude Code inside an isolated macOS VM with
  config-driven egress, mounts, and repo isolation. Ships the
  `claude-vm` launcher skill, the `claude-vm-config-global` and
  `claude-vm-config-repo` config writers, plus the `claude-vm-diff`,
  `claude-vm-apply-local`, and `claude-vm-apply-remote` companion
  skills.

## Read-only public mirror

If you are reading this on
`TheVoskamps/global-claude-plugins-marketplace`, that repo is a
**read-only public mirror**. Issues are welcome here; we triage and fix
them in the upstream private repo. PRs are not accepted.

## Add this marketplace

In Claude Code:

```text
/plugin marketplace add TheVoskamps/global-claude-plugins-marketplace
```

Then browse and install plugins with:

```text
/plugin
```

Or install one directly by name:

```text
/plugin install <plugin-name>@thevoskamps
```

## Marketplace manifest

The marketplace is defined by `.claude-plugin/marketplace.json`. Each
published plugin is one entry in its `plugins` array. See the
[marketplace schema](https://code.claude.com/docs/en/plugin-marketplaces)
for the entry format.
