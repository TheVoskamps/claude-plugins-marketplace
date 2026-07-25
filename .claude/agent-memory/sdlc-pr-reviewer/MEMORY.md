# Memory Index

- [Self-approve blocked, use comment](feedback_self-approve-blocked-use-comment.md) — when gh identity == PR author, --approve fails; re-post body with --comment and state verdict inline
- [Guardrails binary verification](reference_guardrails-binary-verification.md) — verify permission-gate policy by exercising the committed binary with synthetic PreToolUse events, not cmp against a rebuild
- [Verify bash regex in real bash](reference_verify-bash-regex-in-real-bash.md) — Bash tool's shell has empty $BASH_VERSION and mis-evaluates [[ =~ ]] / [^]]; run under explicit `bash` before asserting a regex bug
- [Checkout PR branch before exercising](reference_checkout-pr-branch-before-exercising.md) — review worktree can start on BASE branch; checkout the PR branch first or builds/tests/binaries measure base code (tests won't even compile)
- [Verify mkosi claims via gh api](reference_verify-mkosi-claims-via-gh-api.md) — claude-vm PRs assert mkosi default repart/apt behavior; verify against pinned mkosi source with `gh api contents ...?ref=vNN`, write to repo `.claude/tmp/`
- [Worktree file can be stale after checkout](reference_worktree-file-can-be-stale-after-checkout.md) — after `git checkout <branch>` a working file can be stale (blob != HEAD:path) and Read may get the primary-clone path (on main); verify blob identity before reviewing
- [JSON payload via file, not echo](reference_json-payload-via-file-not-echo.md) — echo '{"p":"a\nb"}' mangles \n into a real newline (invalid JSON) and fakes a "script ignores all input" Critical; feed payloads from a file
- [status --porcelain cannot prove a push](reference_status-porcelain-cannot-prove-a-push.md) — `git log -1` + `git status --porcelain` read clean on an unpushed commit; require a remote comparison in agent "verify it landed" steps
- [Skip fetch when origin ref matches](reference_skip-fetch-when-origin-ref-matches.md) — SSH fetch can time out on a biometric key; if origin/<branch> already equals the PR headRefOid, check out from it and skip the fetch entirely
