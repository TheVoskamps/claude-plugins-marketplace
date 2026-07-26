---
name: test-interactive-shell-handoff-with-script-pty
description: To verify a claimed interactive-shell handoff (exec bash -l, login-program chains, tty/termios claims), reproduce it under `script -q /dev/null` — a real pty — and probe `case $- in *i*`; reasoning about controlling ttys is not enough.
metadata:
  type: reference
---

When a PR claims "on failure we `exec` a login shell and the operator
lands in a working interactive shell", that claim is **testable on the
host** even when the real target is a guest VM you cannot boot.

**The technique:** wrap the handoff in a stub script and run it under
`script -q /dev/null <stub>`, which supplies a real pty. Pipe probe
commands into it with a leading `sleep` so the login shell is up
first, then grep the output:

```bash
cat > inner.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "launcher tty: $(tty)"
exec bash -l
EOF
{ sleep 1; printf 'case $- in *i*) echo PROBE_INTERACTIVE=yes;; *) echo PROBE_INTERACTIVE=no;; esac\n'
  printf 'echo PROBE_TTY=$(tty)\n'; sleep 1; printf 'exit 0\n'; sleep 1; } \
  | script -q /dev/null ./inner.sh 2>&1 | tr -d '\r' | grep -a "PROBE_\|launcher"
```

A real interactive shell shows `PROBE_INTERACTIVE=yes`, the SAME tty
as the launcher, and emits bracketed-paste `[?2004h` around its
prompt — that escape sequence is itself a reliable tell, since only
interactive bash emits it.

**Why it matters:** on PR #180 (claude-vm) the spec demanded an
abnormal claude exit drop the operator into a root shell on the guest
console, and asked whether a termios/session/controlling-tty problem
lurked. The code answer was that `exec` preserves agetty's session
leader and foreground pgrp, and that only `log()` was redirected to
the other console — but "the reasoning looks sound" is weaker than a
demonstration. The pty harness turned it into a verified pass.

**Also check, from the code, before trusting such a handoff:** where
the launcher redirects fd 0/1/2 (a diagnostics redirect to a *different*
console is fine; a redirect of the shell's own fds is not), and whether
the shell binary is actually installed (grep the image's package list —
do not trust the comment that says it is).

Companion to [[verify-bash-regex-in-real-bash]]: both are "exercise the
real artifact under the real interpreter/terminal, not a convenient
proxy."
