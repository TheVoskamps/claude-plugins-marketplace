---
name: probe-forms-that-cannot-prove-gate-carve-outs
description: In the guardrails permission-gate, `ls` sits on NO allow track (defers everywhere) and `>` redirect targets never reach either Engine B operand walk (hasRedirectToFile defers first) — so neither can prove or disprove a carve-out; probe reads with the Read tool / `less`, writes with `tee`/`touch`/`cp`, and verify reviewer-side with a negate-check.
metadata:
  type: reference
---

Two command forms silently measure the wrong thing when probing an
Engine B carve-out (found on PR #208 / #193, round 3):

- **`ls <path>`** is in neither `readOnlyUtilities` nor the
  `classifyPathReader` dispatch (`case "less", "more", "od", "xxd",
  "hexdump":`), so a bash `ls` DEFERS for every path — a doc claiming
  "an `ls` of X is covered" by a read carve-out is a wrong example
  even when the shape genuinely matches the directory node. Probe
  directory-node coverage with the `Read` file tool on the directory
  or `less` on it (both hit `containPathOperands`).
- **`cmd > <path>`** never reaches `containPathOperands` or
  `containWriteOperands`: `sc.hasRedirectToFile` disqualifies the
  allow track and defers (asks for git) before any operand walk. A
  `>` probe therefore defers for carved-out and non-carved-out
  targets alike — it can neither prove a write carve-out works nor
  prove it leaks. Probe write carve-outs with `tee`/`touch`/`cp
  <src> <target>`/`mkdir`, the operand-modelled writers.

These are the write-side/topology siblings of the fixer's
`cat`-is-vacuous lesson (read-only-utility terminal ALLOWs any
contained-or-carved-out operand, so `cat` proves nothing about a read
carve-out).

**Reviewer-side negate-check, cheap and decisive:** in the review
worktree, flip the new predicate (e.g. `scratchAllowEligible`'s new
arm to `return false`), run only the new tests, read which assertions
fail, revert, then `git hash-object <file>` vs
`git rev-parse HEAD:<file>` to prove the revert. On #208 this
separated the load-bearing assertions (Read tool, `less`, the
structural pin) from the vacuous-but-true ones (`cat`, `head`) in one
run, and settled an ambiguous PR-body claim without asking anyone.

Practical note: subagent cwd resets between Bash calls, so run module
commands as `go -C <abs-module-dir> test ./...` instead of cd + go.

Related: [[guardrails-binary-verification]],
[[harness-slugs-can-double-dash]],
[[verify-bounded-cleanup-by-stubbing-kill]] (same extract-and-stub
spirit).
