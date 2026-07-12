---
name: gh-pr-diff-and-active-gate
description: gh pr diff can silently truncate/garble output on PRs with binary-diff commits; and the active permission-gate blocks heredoc-style git commit -m even for plain git (not just gh api)
metadata:
  type: feedback
---

Two environment gotchas hit during the #113 doc-updater run (PR #114),
both worth checking early on any future run in this repo:

**`gh pr diff <N> --patch` can drop entire file sections with no
error** when the PR includes a committed binary (e.g. the guardrails
plugin's compiled `permission-gate` binaries). The binary content
renders as a `GIT binary patch` / `delta NNNN` block that isn't marked
"Binary files differ", and for a PR that also touches several text
files, `gh pr diff` returned a diff that silently omitted 4 of 7 changed
text files (only plugin.json, the two binaries, and README.md showed
up — `dangerous_ops_test.go`, `gh_api_gate.go`, `gh_api_gate_test.go`,
`rules.go` were missing, no truncation warning). The `-e/--exclude`
flag also did not filter the binary sections out as documented.
**Fix:** don't trust `gh pr diff` alone when a PR touches compiled
binaries. Cross-check with `git diff <merge-base> HEAD --stat` (or
`-- <path> <path> ...` to scope to just the text files) using local git
objects, which is unaffected by this gh CLI bug. See
[[verify-territory-not-relay]] for the general "verify against
immutable git state" principle this instantiates.

**The permission-gate (when active/deployed) blocks `git commit -m
"$(cat <<'EOF' ... EOF)"`** — the heredoc-into-command-substitution
form used by the standard commit-message convention — with "a command
whose arguments are not all static literals ... cannot be statically
classified." This is bypass gate 1 (non-static argv) firing on plain
`git`, unrelated to the `gh api` gate this specific PR (#113) fixes.
**Fix:** write the commit message to a scratch file
(`.claude/tmp/commit-msg.txt`) and commit with `git commit -F
<file>` instead — a fully literal argv the gate classifies normally.
This applies to any git repo running the guardrails permission-gate,
not just mid-fix-of-the-gate-itself scenarios.
