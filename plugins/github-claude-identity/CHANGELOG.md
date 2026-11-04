# github-claude-identity changelog

## 0.1.0 — 2026-06-22

Runs `git` and `gh` against GitHub as Claude's own bot identity, a
dedicated GitHub App account distinct from your personal identity, so
Claude's commits, pushes, PRs and issue comments are attributed to it.

- `gh_wrapper` and `git_wrapper` run the two tools under that identity.
- `/gh-create-identity-app` provisions it. The skill walks the UI-gated
  App registration, deploys the token-minting and credential-helper
  scripts to `~/.config/claude-github-app/`, renders the config from
  your App identifiers, applies the per-repo bot-identity override and
  verifies the bot acts correctly. It is idempotent: on a machine or
  repo already configured, it converges instead of starting over.
