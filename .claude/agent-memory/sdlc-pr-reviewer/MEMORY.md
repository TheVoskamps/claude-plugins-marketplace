# Memory Index

- [Self-approve blocked, use comment](feedback_self-approve-blocked-use-comment.md) — when gh identity == PR author, --approve fails; re-post body with --comment and state verdict inline
- [Guardrails binary verification](reference_guardrails-binary-verification.md) — verify permission-gate policy by exercising the committed binary with synthetic PreToolUse events, not cmp against a rebuild
- [Verify bash regex in real bash](reference_verify-bash-regex-in-real-bash.md) — Bash tool's shell has empty $BASH_VERSION and mis-evaluates [[ =~ ]] / [^]]; run under explicit `bash` before asserting a regex bug
- [Checkout PR branch before exercising](reference_checkout-pr-branch-before-exercising.md) — review worktree can start on BASE branch; checkout the PR branch first or builds/tests/binaries measure base code (tests won't even compile)
- [Verify mkosi claims via gh api](reference_verify-mkosi-claims-via-gh-api.md) — claude-vm PRs assert mkosi default repart/apt behavior; verify against pinned mkosi source with `gh api contents ...?ref=vNN`, write to repo `.claude/tmp/`
