---
name: commit-heredoc-gate
description: git commit -m "$(cat <<'EOF' ... EOF)" gets blocked by the static-argument gate in this harness — use git commit -F <file> instead
metadata:
  type: feedback
---

Running `git commit -m "$(cat <<'EOF' ... EOF)"` (the heredoc-into-
command-substitution pattern shown in the orchestrator's own commit
instructions) was blocked here with: "Blocked: a 'git' command whose
arguments are not all static literals (a command substitution,
unresolved variable, or glob) cannot be statically classified and
could reach a dangerous operation through the dynamic token."

**Why:** the harness's command-classification gate cannot statically
verify the contents of a `$(...)` substitution, so it refuses any git
invocation whose argument contains one — even a harmless multi-line
commit message.

**How to apply:** when a commit message needs to be multi-line (which
is normal per the git-workflow commit-message rules), write the
message to a scratch file under `.claude/tmp/<task-slug>/` first, then
run `git commit -F <scratch-file>`. Clean up the scratch file after a
successful commit. This sidesteps the gate entirely since `-F <path>`
is a static literal argument.
