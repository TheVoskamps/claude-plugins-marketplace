---
name: bash-scripts-test-under-bash-not-zsh
description: The Bash tool's shell is zsh here; test bash payload scripts with `bash -c`/`bash <file>`, not by sourcing into the interactive shell — sourcing gives misleading exit 127 / empty output
metadata:
  type: feedback
---

When ad-hoc-testing a `#!/usr/bin/env bash` script or sourcing a bash
library (e.g. `plugins/claude-vm/payload/lib/config.sh`) to drive one of
its functions, run it under **bash explicitly** — `bash -c '...'` or
`bash <script>` — not by `. lib/config.sh` directly in a `Bash` tool
call.

**Why:** the `Bash` tool's login shell on this machine is **zsh**, not
bash. Sourcing a bash script into zsh and calling its functions
produced misleading symptoms during issue #104: a function that ran
`yq ...` returned exit **127** ("command not found") and empty output,
even though `command -v yq` in the same shell succeeded and the same
`yq` expression run bare worked. `set -x` showed the function body
executing but silently producing nothing. The function was correct —
the zsh-vs-bash sourcing was the artifact. Wrapping the exact same
drive in `bash -c '...'` immediately produced the right output.

**How to apply:** for any issue touching shell scripts in this repo
(claude-vm's payload/lib is all bash), when you want to exercise a
function interactively, do
`bash -c '. plugins/.../lib/config.sh; my_func args...'`. The committed
test suites already do this correctly (they are `bash <file>` runs), so
prefer just running the real test file (`bash payload/test/config-test.sh`)
over hand-rolling a source-and-call in the tool's zsh. Two yq gotchas
also cost time in the same run and are worth remembering: mikefarah yq
has **no `reduce`** (that is jq syntax — build objects in shell or with
`with_entries`), and `"" | from_yaml` **errors with EOF** (guard an
empty YAML fragment to the literal `{}` before piping it through
`from_yaml`).
