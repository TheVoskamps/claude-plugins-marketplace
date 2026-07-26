---
name: vfkit-rest-shutdown-and-5s-force-timer
description: vfkit v0.6.4's own signal handler force-stops the guest after a HARDCODED 5s; clean claude-vm exit needs REST RequestStop + process-group isolation, not just --restful-uri
metadata:
  type: project
---

The claude-vm "never exits cleanly (`failed to wait for VM stop ... forcing
stop` on every exit)" defect (#179 real-boot) has a precise mechanism, verified
against vfkit v0.6.4 source (`gh api repos/crc-org/vfkit/contents/...?ref=v0.6.4`
→ base64 -d; the raw file lives in `cmd/vfkit/main.go` + `pkg/rest/`):

- vfkit's OWN SIGINT/SIGTERM handler (`SetupExitSignalHandling` → `shutdownFunc`
  in `cmd/vfkit/main.go`) calls `vfVM.RequestStop()` (ACPI) then
  `waitForVMState(...Stopped, time.After(5*time.Second))` — a **hardcoded 5s
  deadline** — and on timeout logs `forcing stop` and `vfVM.Stop()` (force).
  The real guest reliably takes >5s to halt, so a terminal Ctrl-C that reaches
  vfkit ALWAYS force-kills.
- vfkit's REST channel maps `POST /vm/state {"state":"Stop"}` → the SAME
  `RequestStop()` but with **NO 5s force-timer** (the REST handler just requests
  the stop; `runVirtualMachine` then waits naturally). Routes:
  `GET/POST /vm/state`, `GET /vm/inspect`; body is `{"state": "..."}`
  (`VMState{State string json:"state"}`); values Stop/HardStop/Pause/Resume;
  `unix://<path>` URI (host forbidden, path required, ≤104 bytes).

**How to apply:** to get a clean claude-vm exit you must (a) launch
`vfkit --restful-uri unix://$RUN/vfkit.sock`, AND (b) keep the terminal Ctrl-C
OFF vfkit so its 5s force-timer never starts — done by backgrounding vfkit under
`set -m` (own process group), then driving the stop from the launcher's cleanup
trap: POST Stop, poll (generous timeout), POST HardStop, SIGKILL as last resort.
`--restful-uri` alone is NOT enough; without the signal isolation vfkit's own
handler still races and force-kills at 5s. Talk to the socket with
`/usr/bin/curl --unix-socket <sock> -X POST -d '{"state":"Stop"}'
http://vfkit/vm/state` (curl+perl+lsof are all base-macOS at /usr/bin,/usr/sbin).

**RESIDUAL RISK (unverified, needs real boot):** a process in a non-foreground
process group that `read()`s the controlling tty normally gets SIGTTIN and
stops. If vfkit's stdio-console read trips this under `set -m`, guest keyboard
input freezes — breaking the claude-IS-the-VM model. Could not be tested in a
headless worktree (no /dev/tty). If it manifests, hand the terminal fg group to
vfkit's group via tcsetpgrp while still trapping Ctrl-C in the launcher. See
[[unit-tests-are-not-real-runs]] and [[real-build-verification-not-unit-tests]].
