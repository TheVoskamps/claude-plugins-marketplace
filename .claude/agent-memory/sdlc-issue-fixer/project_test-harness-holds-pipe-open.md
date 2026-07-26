---
name: test-harness-holds-pipe-open
description: "A long-lived stub child in $(...) holds the command-substitution pipe open, so a timing test silently measures the pipe instead of the code under test."
metadata:
  type: project
---

`OUT="$(run_harness)"` waits for **stdout to close**, not for the harness to
exit. Any background stub child inside it inherits that pipe, so a stub with a
60s lifetime makes the command substitution take 60s — even when the function
under test returned in 1s.

**Why:** while testing claude-vm's bounded `reap_vfkit` (PR #180), the suite
that was supposed to prove "returns in ~1s" took 120s+. The reap was correct;
the harness was measuring the stub's pipe. A timing assertion built that way
either times out or, worse, passes for the wrong reason — the test looks like
evidence and is not. Compounding it: a foreground `sleep 60` in the stub queues
a SIGTERM behind itself, so the stub appears to ignore signals it does not
actually ignore.

**How to apply:** when a shell test measures how long something takes:

- Redirect the stub's stdio: `"$stub" >/dev/null 2>&1 </dev/null &`.
- Have the harness write its result to a **file** and `cat` that afterwards,
  rather than echoing to the substituted stdout.
- In a stub that must be signal-responsive, use `sleep N & wait $!` rather than
  a foreground `sleep N`, so signals are delivered promptly.
- Sanity-check the wall-clock: if a "1 second" assertion takes minutes, suspect
  the harness before the code. Related: [[bounded-poll-then-unbounded-wait]].

This is the *timing-measurement* face of the same mechanism as
[[backgrounded-proc-in-command-substitution-hangs]] — that memory covers the
hang; this one covers the subtler case where the test completes but the number
it reports is the pipe's lifetime, not the code's.
