---
name: verify-bounded-cleanup-by-stubbing-kill
description: To prove a reap/cleanup escalation is bounded on EVERY path (incl. the give-up path), extract the real function bodies with sed and stub `kill` so `kill -0` always reports alive — a SIGTERM-ignoring child only reaches the second-to-last rung.
metadata:
  type: reference
---

Reviewing a "bounded" process-reap / cleanup escalation (grace →
SIGTERM → SIGKILL → give up), the load-bearing question is whether the
**give-up path** really skips the blocking `wait`. A normal test child
can't get you there: `trap "" TERM` only survives to the SIGKILL rung,
and nothing in userspace survives SIGKILL.

**The technique:** extract the real function bodies verbatim
(`sed -n '<start>,<end>p' src.sh > reap.inc`), source them in a
harness, shorten the tick constants, and **stub `kill` as a shell
function** so the process appears immortal:

```bash
kill() { case "$1" in -0) return 0 ;; *) return 0 ;; esac; }
```

Now every rung expires, and you observe directly whether the function
returns (and with what status) or blocks in `wait`. Use `builtin kill`
to clean up the real child afterward.

Run BOTH harnesses (real SIGTERM-ignoring child, and stubbed-kill
give-up) under `/bin/bash` 3.2.57 **and** a modern bash — the macOS
system bash is a plausible host interpreter and `seq`/`wait`/errexit
interactions can differ.

**What this caught / confirmed:** on claude-vm PR #180, the prior round
found a `seq 1 50` poll followed by an *unconditional* `wait` — a
bounded poll then an unbounded block, i.e. not a bound at all. The
fixed shape reached the blocking `wait` only after confirming the
process was gone; the stubbed-kill harness proved the give-up path
returned `rc=0` with the synthetic status and never entered `wait`.

**Related things worth checking in the same review:** that the synthetic
give-up status is nonzero (so it routes to the conservative
retain/preserve branch), that the only consumer is a `= "0"` test
rather than an exact-value match, and that any test asserting the value
DERIVES it from source (`sed -n 's/^CONST=\([0-9]*\)$/\1/p'`) instead of
hardcoding it. Also verify the tty/terminal restore is ordered BEFORE
the reap and re-asserted after — a bounded-but-slow reap still strands
a raw-mode terminal for the whole window.

Companion to [[verify-bash-regex-in-real-bash]] (exercise under the
real interpreter) and [[checkout-pr-branch-before-exercising]] (be on
the PR branch first).
