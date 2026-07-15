# Memory Index

- [Issue 113 GraphQL scanner hardening](issue-113-graphql-scanner-hardening.md) — first-match-vs-scan-all and paren-depth-before-brace bug classes in gh-api gate scanners
- [Docs locality: packaging vs. hook-event](project_docs-locality-packaging-vs-hook-event.md) — plugin-authoring-constraints.md (packaging) vs. hook-event-notes.md (per-event runtime facts); don't conflate
- [Commit heredoc gate](feedback_commit-heredoc-gate.md) — `git commit -m "$(cat <<EOF...)"` is blocked here; use `git commit -F <scratch-file>` for multi-line messages
- [Worktree path, not main clone](feedback_worktree-path-not-main-clone.md) — Read/Edit the worktree-absolute path; main-clone path is a different checkout and gives a stale file view
