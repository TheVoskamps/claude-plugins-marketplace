# claude-plugins-marketplace

A [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces)
for The Voskamps' Claude Code plugins.

## Published plugins

The marketplace currently ships these plugins (one entry each in
`.claude-plugin/marketplace.json`):

- **`issues`** — GitHub issue tracking verbs and repo/user config.
- **`issues-jira`** — optional Jira backend for the issue verbs.
- **`sdlc`** — issue grooming and end-to-end orchestration, with a
  theorem-based PR review pipeline.
- **`github-prs`** — GitHub pull-request operations, from opening and
  diffing a PR through reviewing it and linking it to the issues it
  closes. GitHub-only by design.
- **`github-setup`** — GitHub repo provisioning: identity, PR
  automation, security and protection posture, and the move from
  private to public.
- **`git-tools`** — git-side helpers for the issue-branch lifecycle,
  plus unit-test generation.
- **`cc-tools`** — Claude Code meta-skills: global rules, feature/bug
  watchlist status, what's-new-since-last-run — both filtered to the
  topics in your own config, which a suggester widens from this
  machine's Claude configuration on your yes — and agent-memory
  curation from a session's scratchpad inbox into the repo's own
  documentation.
- **`github-claude-identity`** — run git + gh against GitHub as Claude's
  own bot identity (a dedicated GitHub App account) distinct from the
  user's personal identity.
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
- **`writing-tools`** — writing and text-editing helpers, including
  masking inappropriate language character-for-character.
- **`auto-mode-tools`** — tune and personalize the Claude Code auto
  mode classifier config against this machine's facts.

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
