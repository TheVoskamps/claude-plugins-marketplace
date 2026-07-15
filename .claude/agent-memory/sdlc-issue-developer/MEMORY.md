# Memory Index

- [permission-gate is self-hosting](permission-gate-self-hosting.md) — the guardrails gate is ACTIVE while you edit it; it will block your own git/sed/mkdir; work with it, not around it
- [Heredoc commit blocked by sandbox gate](feedback_heredoc-commit-sandbox-gate.md) — use `git commit -F <file>` for multi-line commit messages in subagent worktrees, not `-m "$(cat <<EOF...)"`.
- [Stale origin/main ref after fetch](feedback_stale-origin-main-ref-after-fetch.md) — verify `origin/<branch>` actually advanced before `switch -c`; fetch success ≠ ref updated in fresh worktrees
- [Verify tool names against docs](feedback_verify-tool-names-against-docs.md) — when pruning agent tools: frontmatter, fetch live Claude Code docs rather than trusting the issue body or training priors
- [gh-repo-setup-protection runtime matrix](gh-repo-setup-protection-runtime-matrix.md) — the protect skill's CodeQL/gate workflows use detect→matrix→aggregator; empty-matrix aggregator MUST use if: always() or the phantom-check hang returns
