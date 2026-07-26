---
name: backgrounded-proc-in-command-substitution-hangs
description: capturing a bg process's pid via PID="$(start_listener)" hangs unless the bg process's stdout is redirected; it inherits the subshell's stdout and keeps it open
metadata:
  type: project
---

Test-harness gotcha hit while writing endpoint-test.sh (#179): a helper that
backgrounds a long-lived process and echoes its pid, called as
`PID="$(start_listener ...)"`, HANGS. Command substitution reads until the
subshell's stdout fd closes, but the backgrounded child inherits that same
stdout fd and holds it open for its whole lifetime (a `sleep 30` listener),
so `$(...)` blocks 30s instead of returning the pid immediately.

**Fix:** redirect the backgrounded process's own stdout/stderr inside the
helper: `perl ... >/dev/null 2>&1 &  echo $!`. Then only `echo $!` writes to
the captured stdout and `$(...)` returns at once.

**How to apply:** any shell test that stands up a real background listener
(perl `IO::Socket::UNIX`/`INET`, nc, socat) and captures its pid via command
substitution must redirect the listener's fds. Symptom is a test that appears
to "pass but take ~30s" or times out. Base-macOS perl provides real
unix/TCP listeners (`IO::Socket::UNIX`/`INET`) for liveness-check tests without
socat (which is not installed on stock macOS).
