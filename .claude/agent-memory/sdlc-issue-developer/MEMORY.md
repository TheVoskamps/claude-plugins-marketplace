# Memory Index

- [permission-gate is self-hosting](permission-gate-self-hosting.md) — the guardrails gate is ACTIVE while you edit it; it will block your own git/sed/mkdir; work with it, not around it
- [Heredoc commit blocked by sandbox gate](feedback_heredoc-commit-sandbox-gate.md) — use `git commit -F <file>` for multi-line commit messages in subagent worktrees, not `-m "$(cat <<EOF...)"`.
- [Stale origin/main ref after fetch](feedback_stale-origin-main-ref-after-fetch.md) — verify `origin/<branch>` actually advanced before `switch -c`; fetch success ≠ ref updated in fresh worktrees
- [Verify tool names against docs](feedback_verify-tool-names-against-docs.md) — when pruning agent tools: frontmatter, fetch live Claude Code docs rather than trusting the issue body or training priors
- [gh-repo-setup-protection runtime matrix](gh-repo-setup-protection-runtime-matrix.md) — the protect skill's CodeQL/gate workflows use detect→matrix→aggregator; empty-matrix aggregator MUST use if: always() or the phantom-check hang returns
- [Test bash scripts under bash, not zsh](feedback_bash-scripts-test-under-bash-not-zsh.md) — the Bash tool's shell is zsh; drive bash payload funcs with `bash -c`, not by sourcing. Plus: mikefarah yq has no `reduce`; `""|from_yaml` errors EOF
- [go mod cache reads blocked, use go doc](gomodcache-outside-repo-use-go-doc.md) — gate blocks ~/go/pkg/mod reads even when the issue says it's fine; use `go doc <pkg>.<Symbol>` instead
- [mikefarah yq unique does not sort](mikefarah-yq-unique-does-not-sort.md) — `unique` de-dupes in first-seen order; use `unique | sort` for an order-insensitive canonical form (hashing/cache keys)
- [claude-vm mkosi third-party apt](claude-vm-mkosi-third-party-apt.md) — build-time third-party apt repos go in the mkosi SandboxTree (mkosi.sandbox/etc/apt/...), and signed-by must be the runtime /etc/apt path, not the staging path
