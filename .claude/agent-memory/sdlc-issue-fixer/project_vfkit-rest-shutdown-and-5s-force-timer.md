---
name: vfkit-rest-shutdown-and-5s-force-timer
description: vfkit v0.6.4 force-stops the guest after a HARDCODED 5s once it receives a terminating signal, so claude-vm cannot rely on a host-driven vfkit stop at all -- the guest must power itself off
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
  the stop; `runVirtualMachine` then waits naturally).

**REJECTED approach (do not repeat):** an earlier pass tried launching vfkit
with `--restful-uri`, backgrounding it under `set -m` (its own process group)
so a terminal Ctrl-C wouldn't reach vfkit's 5s-timer signal handler, then
driving the stop from the launcher's cleanup trap (POST Stop, poll, POST
HardStop, SIGKILL as last resort). This was **verified wrong** on a real
interactive boot, not just risky: vfkit v0.6.4 reads the controlling terminal
via `NewFileHandleSerialPortAttachment(os.Stdin, os.Stdout)`
(`pkg/vf/virtio.go`) and does not ignore SIGTTIN or manage the foreground
process group. A process in a background process group that reads the
controlling tty gets SIGTTIN and stops — so `set -m` **freezes guest keyboard
input**, trading the forced-stop bug for an input-freeze bug.

**Correct model (issue #179, current):** the guest powers itself off. claude
is the only workload, so claude exiting == the session is over == the VM
should terminate. The boot launcher captures claude's exit status: exit 0
(deliberate quit) → guest runs `systemctl poweroff` (fallback `poweroff(8)`);
nonzero (e.g. 137/SIGKILL) → the launcher `exec`s an interactive root **login
shell** on hvc1. "Leave the VM up" alone was not enough and was corrected in
PR #180 review: with `Restart=no` on the getty, hvc0 attached host-side to a
log FILE, and no sshd in the guest, a merely-still-running VM had no console
anyone could reach — worse than powering off. The shell must be `exec`ed from
the launcher (which replaces it) and the getty must never independently re-exec
the launcher, or claude reruns and the respawn loop returns.

vfkit then exits on its own; the host launcher reaps it and decides
discard/retain on that real exit status. No REST channel, no `--restful-uri`,
no `set -m`, no `vfkit_rest_uri` in `run.meta` — vfkit runs foreground,
normally.

**Do not read the 5s above into host-side reap tuning.** It is vfkit's own
force-stop deadline, sourced from vfkit v0.6.4. The launcher's `reap_vfkit`
rungs are an independent patience budget; a review harness that reproduced the
old unbounded reap used a scripted stub child with no vfkit involved, so its
timings said nothing about vfkit. See
[[bounded-poll-then-unbounded-wait]] and
[[getty-respawn-is-restart-not-dash]]. See
[[claude-vm-four-file-config-and-per-run-clone]] for the surrounding
per-run-clone design this shutdown model integrates with.
