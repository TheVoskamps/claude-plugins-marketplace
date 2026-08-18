# claude-plugins-marketplace

A [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces)
for The Voskamps' Claude Code plugins.

## Published plugins

The marketplace currently ships these plugins (one entry each in
`.claude-plugin/marketplace.json`):

- **`issues`** — GitHub issue tracking verbs and repo/user config.
- **`issues-jira`** — optional Jira backend for the issue verbs.
- **`sdlc`** — issue grooming and orchestration, the
  developer/fixer/doc/memory-scrubber agents, and a theorem-based PR
  review pipeline.
- **`github-prs`** — GitHub PR-operations skills: create, diff, and
  review-submit a PR; flip a PR draft/ready; link a PR to the issues
  it closes via one closing keyword each in the PR body; and report
  which issues a PR body closes. GitHub-only by design.
- **`github-setup`** — GitHub repo provisioning (App identity, PR
  automation, branch protection, public mirror, history scrubbing,
  private-to-public promotion).
- **`git-tools`** — create the correctly-named issue branch, for one
  issue or a batch of them, off the right base; recover the issue set
  back out of a branch name and reconcile a claimed issue list against
  it; clean up merged branches and stale worktrees; and generate unit
  tests.
- **`cc-tools`** — Claude Code meta-skills: load all global rules,
  track Claude Code feature/bug watchlist status, and curate a repo's
  `.claude/agent-memory/` in one acting pass (`agent-memory-cleanup`).
- **`github-claude-identity`** — run git + gh against GitHub as Claude's
  own bot identity (a dedicated GitHub App account) distinct from the
  user's personal identity. Bundles `gh_wrapper`, `git_wrapper`, and the
  `gh-create-identity-app` provisioning skill.
- **`guardrails`** — compiled PreToolUse permission-gate hook: command
  classification and worktree/cross-repo path containment, three-tiered
  (deny-with-teaching, positive-grounds allow, enumerated hard asks)
  with the judgment middle deferred to the automode evaluator.
- **`block-background-agents`** — PreToolUse policy hook that denies
  background agent spawns (`run_in_background: true`) so a detached
  subagent's permission prompts can still bubble up to the user.
- **`claude-vm`** — run Claude Code inside an isolated Linux micro-VM
  on macOS with config-driven egress, mounts, guest environment
  variables, and repo isolation.
  Ships the `bin/claude-vm` preflight launcher, the `claude-vm` skill,
  the `claude-vm-config-global` and `claude-vm-config-repo` config
  writers, plus the `claude-vm-diff`, `claude-vm-apply-local`, and
  `claude-vm-apply-remote` companion skills.
- **`show-loaded-rules`** — `InstructionsLoaded` hook that surfaces a
  one-line message for every CLAUDE.md / `.claude/rules/*.md` file
  loaded into context, so you can see which rules files are in play
  without running `--verbose`.
- **`show-loaded-skills`** — `UserPromptExpansion` and `PreToolUse`
  (matcher `Skill`) hooks that surface a one-line message every time a
  skill loads, whether typed as a command or invoked by the model.
- **`show-agent-calls`** — `PreToolUse` (matcher `Agent|Task`) hook
  that surfaces the agent type, parameters, and full prompt for every
  subagent spawn, without `--verbose`.
- **`writing-tools`** — writing and text-editing helpers. Currently
  ships `mask-inappropriate-language`, which replaces inappropriate
  language (profanity, slurs, strong insults) in provided text or a
  file with asterisks, character-for-character.

## Add this marketplace

In Claude Code:

```text
/plugin marketplace add TheVoskamps/claude-plugins-marketplace
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

## Contributing

This is a public repository. Contributions are welcome:

- **Fork** the repository and create a feature branch from the default
  branch.
- **Open a pull request** from your fork. PRs require a passing CI run,
  code-owner review (`@evoskamp`), and all review conversations
  resolved before they can merge.
- **File an issue** to report a bug or propose a change. Any logged-in
  GitHub user can open and comment on issues.

Outside contributors have read access: you can fork, open PRs from your
fork, and file/comment on issues. Push access, merging, and issue
triage are reserved for maintainers.
