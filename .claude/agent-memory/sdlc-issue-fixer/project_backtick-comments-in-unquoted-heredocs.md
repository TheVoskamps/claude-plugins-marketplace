---
name: backtick-comments-in-unquoted-heredocs
description: paired backticks inside a "#" comment line, in an UNQUOTED bash heredoc, trigger real command substitution and can masquerade as multiple unrelated bugs
metadata:
  type: project
---

Class of defect found and fixed in `plugins/claude-vm/payload/provisioners/podman-mkosi.sh`
(issue #105 / PR #161, real end-to-end mkosi build failure, fixed in commit
`046a5e8`).

**The bug**: a heredoc opened unquoted (`<<CONF`, not `<<'CONF'` — required
here so `$GUEST_SUITE` interpolates into the generated `mkosi.conf`) does
NOT get `#`-comment parsing. `#` is inert inside a heredoc body. So a prose
comment like `` # falls back to `cp --preserve=...,xattr`, which fails `` —
written as markdown-style code-quoting for a human reader — is actually
paired-backtick **command substitution** syntax to the shell. Bash executes
`cp --preserve=...,xattr` (and, on the next flagged line, `hashed:`) as real
host commands and splices their stderr/stdout into the heredoc's output in
place of the comment text.

**Why it looked like two/three unrelated bugs**: the PR review brief that
spawned the fix described this as two separate host-side failures — "Bug 1"
(`cp: illegal option --`, framed as a GNU-vs-BSD `cp` flag incompatibility
in some invocation of our own `cp`) and "Bug 2" (`hashed:: command not
found`, framed as a heredoc-quoting regression specific to the #105
branch's diff). Both hypotheses were wrong once the real host path was
exercised: there is no `cp --preserve` invocation anywhere in the actual
script (grep confirmed), and `git diff origin/main..HEAD` on the file
showed the `mkosi.conf` heredoc body is byte-identical between main and
the branch (purely additive diff elsewhere) — so it isn't a #105
regression at all, it's a **preexisting bug on `main`** that simply hadn't
been hit by a real build in a while. Both observed failures collapsed into
one root cause once reproduced directly.

**How this was actually diagnosed** (not from unit tests — the branch's
151 pure-function tests caught none of this because none of them render or
execute the generated recipe files): stub only the external command that
blocks a full run (`podman`, to intercept right before `podman run` hands
off to the container) and let the REAL script run to completion on that
path with `bash -x`. The trace immediately showed `++ cp
--preserve=...,xattr` / `++ hashed:` as actual double-`+` (command
substitution) executions, at which point `grep -n '`' <heredoc-body-range>`
found the two backtick-paired comment lines instantly.

**The fix**: replace paired backticks with single quotes in the two
comment lines (single quotes are inert to the shell, so no substitution
risk, and they read identically as human prose). Also swept the same
heredoc body and the sibling `<<INNER` heredoc for any other backtick
pairs — found none.

**How to apply**: whenever debugging a real build/runtime failure whose
error text doesn't match anything the script's own logic obviously does
(a command that "shouldn't" be running), check whether the failing
fragment is prose sitting inside an UNQUOTED heredoc. Grep the heredoc
body for backtick pairs, `$(...)`, or bare `$VAR` that isn't meant to
interpolate. A reviewer's stated root-cause hypothesis (e.g. "the #105
branch changed heredoc quoting") should be verified against
`git diff origin/main..HEAD` before accepting it — it can be flatly wrong,
and the actual defect can be older and unrelated to the branch under
review. See [[real-build-verification-not-unit-tests]] for the broader
verification-method lesson.
