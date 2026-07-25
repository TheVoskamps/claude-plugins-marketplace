---
name: exec-prose-sweep-two-senses
description: claude-vm "exec" prose sweep (PR #180) has TWO senses — launcher-execs-claude (stale) vs guest-runs-RO-binary (provenance); "right before claude execs" is the recurring wrapped-twin miss
metadata:
  type: reference
---

When reviewing claude-vm stale-"exec"-prose sweeps (PR #180, issue #179,
the self-poweroff redesign), the word "exec" carries two DISTINCT
concepts and only one is the stale class:

- **Launcher-execs-claude (STALE class)**: since the redesign the boot
  launcher runs claude as a CHILD (`"$CLAUDE_BIN" "$@"`, not `exec`) so
  it can read `$?` and decide poweroff-vs-shell. Any current-behavior
  prose saying the launcher/guest "execs claude" is false as mechanism.
- **Guest-runs-RO-binary (provenance)**: "the guest runs the RO-mounted
  binary from /mnt/claudebin" is about WHICH binary runs (vs the native
  installer path), not HOW the launcher invokes it. But the author DID
  reword this phrase "execs -> runs" at build-guest-image.sh:862 in the
  round-8 commit, so they treat it as in-scope for the sweep — leaving
  the README/SKILL twins is the same twin-miss class.

Legitimate survivors (NOT findings): `exec tinyproxy`, `exec 3<>`,
`bin/claude-vm:207 exec "$LAUNCHER"` (real host-side exec), `libexec`/
`ExecStart` (systemd), agetty exec-ing its login-program, apt-get being
run by boot_apt_phase, negative test assertions, LAUNCHER_LOGIC_REV
historical changelog stanzas, explicit "earlier shape exec'd" retros.

**Recurring wrapped-twin miss**: "right before claude execs" (README ~492
and SKILL ~571, a twin pair). Introduced in 31d8cb3 (#106 boot-apt work,
pre-#179), never updated by ANY #179 sweep commit incl. round-8's
wrap-proof pass. It is a live current-behavior ordering statement whose
verb ("claude execs") is stale. When a sweep commit's message claims
"every remaining hit is a negative assertion / historical changelog /
retrospective", verify by reading EACH live hit — that extinction claim
is load-bearing and has been false in multiple rounds of this PR.

**How to apply**: for a claude-vm exec-prose sweep review, run
`grep -rniE exec` over plugins/claude-vm, then classify each hit into
(stale-launcher-execs-claude | provenance-guest-runs-binary | legit
survivor). The provenance twins and the "right before claude execs"
twins are the ones that keep slipping through line-based greps because
they wrap across newlines or read as generic English.
