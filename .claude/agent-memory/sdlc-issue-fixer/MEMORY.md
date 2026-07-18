# Memory Index

- [Issue 113 GraphQL scanner hardening](issue-113-graphql-scanner-hardening.md) — first-match-vs-scan-all and paren-depth-before-brace bug classes in gh-api gate scanners
- [Docs locality: packaging vs. hook-event](project_docs-locality-packaging-vs-hook-event.md) — plugin-authoring-constraints.md (packaging) vs. hook-event-notes.md (per-event runtime facts); don't conflate
- [Commit heredoc gate](feedback_commit-heredoc-gate.md) — `git commit -m "$(cat <<EOF...)"` is blocked here; use `git commit -F <scratch-file>` for multi-line messages
- [Worktree path, not main clone](feedback_worktree-path-not-main-clone.md) — Read/Edit the worktree-absolute path; main-clone path is a different checkout and gives a stale file view
- [Cross-plugin lib sharing unresolved](project_cross-plugin-lib-sharing-unresolved.md) — skills/lib/repo-config.md not readable cross-plugin; github-workflow (#143/PR150) final fix was zero coupling — GitHub-only `gh` wrappers need no guard at all
- [Cross-plugin lib sharing: resolved for real config needs](project_cross-plugin-lib-sharing-resolved-for-real-config-needs.md) — git-tools:git-branch-create (formerly gh:branch-create) / github-prs:pr-create need 2 real fields each; fixed via inline 2-field parse, not a bare cross-plugin Read (which cannot resolve)
- [Backtick comments in unquoted heredocs](project_backtick-comments-in-unquoted-heredocs.md) — paired backticks in a heredoc comment ARE command substitution; can masquerade as multiple unrelated bugs (claude-vm #105/#161)
- [Real-build verification, not unit tests](project_real-build-verification-not-unit-tests.md) — stub only the blocking external cmd (e.g. podman), run the real script's real path, inspect generated artifacts literally
- [PR branch rebased under checkout](project_pr-branch-rebased-under-checkout.md) — this repo's rebase-sweep automation can force-rebase a PR branch mid-session; recover via format-patch+am onto the new tip, never force-push
- [Stale worktree holds branch; cwd resets](project_stale-worktree-holds-branch-and-cwd-does-not-persist.md) — prior fixer left a worktree checked out on the branch; inspect via git --git-dir/--work-tree (not cd/-C), remove if clean; confirms subagent cwd does NOT persist across Bash calls
- [Git command-form gate: cd then bare git](feedback_git-command-form-gate-cd-then-bare-git.md) — both `cd X && git ...` and `git -C X ...` are blocked; only a bare `cd X` call then a separate bare `git ...` call works
