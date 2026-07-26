---
name: bounded-poll-then-unbounded-wait
description: "A bounded poll loop followed by an unconditional blocking `wait` is NOT a bound; the give-up path must return before any wait. Verify with a negative control."
metadata:
  type: project
---

A poll loop with a tick budget followed by an **unconditional** blocking call
(`wait "$PID"`, `join()`, `recv()`) is not a bounded function — on expiry it
blocks for as long as the child lives. The tick budget only decides *when* you
start blocking forever.

**Why:** claude-vm's `reap_vfkit` (issue #179, PR #180) had exactly this shape.
The `seq 1 50` loop neither killed the child nor skipped the following `wait`,
so a vfkit that outlived 5s hung `cleanup()` indefinitely — and because
`cleanup()` reaped *before* restoring the host tty, the operator's terminal
stayed in raw mode for the whole hang. Two coupled defects from one ordering
mistake.

**How to apply:** when reviewing or writing a "bounded wait":

- The give-up branch must `return` **before** any blocking call. Assert this
  structurally in a test (compare the source line numbers of the give-up
  assignment and the `wait`), not just behaviourally.
- Escalate through finite rungs (grace → SIGTERM → SIGKILL), each with its own
  tick budget, and treat "survived every rung" as a real outcome with its own
  synthetic status — do not fall through.
- Order teardown so user-visible state (tty restore, spinner stop, lock
  release) happens **before** the reap, and re-assert after it if the reaped
  process could have re-corrupted that state. Restores of that kind are
  idempotent, so running them on both sides is cheap.
- **Write a negative control.** Reproduce the OLD shape in a scratch script and
  confirm it hangs past a watchdog while the new one returns in ~1s. Without
  it, a test that passes proves nothing about whether it would have caught the
  bug. See [[test-harness-holds-pipe-open]] for the trap that makes such a
  test silently measure the wrong thing.
