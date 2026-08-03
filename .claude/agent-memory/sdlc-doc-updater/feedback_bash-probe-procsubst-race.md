---
name: bash-probe-procsubst-race
description: When probing real bash to settle an "does bash run this substitution" doc claim, sleep before checking the marker — a process substitution's child is async and reads as "did not run" if you check immediately.
metadata:
  type: feedback
---

Settling a permission-gate doc claim about *what bash itself runs*
(`: ${Q:-<(cmd)}`, an unquoted vs `<<'EOF'` here-document body, `'$(cmd)'`)
means running the shape in real bash with a marker side effect
(`touch M` in a `mktemp -d`) — not reasoning from the parser. Compare
`/bin/bash` (3.2.57 on macOS) against `/opt/homebrew/bin/bash` (5.x) in
the same probe, because the docs claim identical behavior on both.

**Why:** a PROCESS substitution's command runs in an ASYNC child. Checking
the marker immediately after `bash -c` exits reports "did not run" for
`: ${Q:-<(touch M)}`, which is the opposite of the truth and would have
had me "correct" an accurate README sentence into a false one. A `sleep`
between the run and the check flipped every process-substitution row.
Command substitutions are synchronous and never showed the race.

**How to apply:** write the probe as a script file in the scratchpad and
run `bash <script>` — a multi-command inline pipeline with redirects gets
refused by the worktree-isolation check. Put `sleep 0.5` after every run,
and include a known-RAN control (`: <(touch M)`) so a probe that measures
nothing announces itself.

Its sibling for the gate's own verdicts is
[[feedback_probe-the-gate-binary-not-the-walk]]: a counterfactual claim
("deleting this skip would turn X back into a prompt") is settled by
patching the condition in `engine_a_bash.go`, re-running the probe test,
then `git checkout` on the file — comment-only Go edits are what force a
three-binary rebuild, a temporary one you revert does not.
