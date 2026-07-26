---
name: exec-prose-sweep-two-senses
description: claude-vm "exec" prose has TWO senses — launcher-execs-claude (stale mechanism claim) vs guest-runs-RO-binary (provenance, about WHICH binary runs); a pattern-shaped grep misses real prose and only a token-exhaustive hand-classified audit closes it
metadata:
  type: reference
---

When reviewing claude-vm "exec"-prose for staleness, the word "exec"
carries two DISTINCT concepts and only one is the stale class:

- **Launcher-execs-claude (STALE class)**: the boot launcher runs
  claude as a CHILD (`"$CLAUDE_BIN" "$@"`, not `exec`) so it can read
  `$?` and decide poweroff-vs-shell. Any current-behavior prose saying
  the launcher/guest "execs claude" is false as mechanism.
- **Guest-runs-RO-binary (provenance)**: "the guest runs the RO-mounted
  binary from /mnt/claudebin" is about WHICH binary runs (vs the native
  installer path), not HOW the launcher invokes it — a distinct,
  legitimate use of "exec" in prose that is not itself stale, though a
  sweep that reworded one instance of it should be checked for missed
  twins elsewhere.

Legitimate survivors (NOT findings): `exec tinyproxy`, `exec 3<>`,
`bin/claude-vm:... exec "$LAUNCHER"` (real host-side exec), `libexec`/
`ExecStart` (systemd), agetty exec-ing its login-program, apt-get being
run by boot_apt_phase, negative test assertions, `LAUNCHER_LOGIC_REV`
historical changelog stanzas, explicit "earlier shape exec'd" retros.

**The method that closes this class**: a pattern-shaped grep
("execs? claude", "claude execs?") misses real prose, because real
prose violates the pattern (e.g. "before claude execs", "execs the
RO-mounted binary" — object before the verb, or object not claude).
`grep -rniE exec` over the WHOLE plugin, plus `grep -rc` over every
file so the zero-hit files are proven zero, then classify EVERY hit by
hand into (stale-current-behavior | negative assertion |
historical/retrospective | genuine exec). Never trust a needle-shaped
grep, and never trust a commit's own "all sites fixed" claim without
re-running the grep yourself.

**Changelog-stanza boundary rule**: `build-guest-image.sh`'s
`LAUNCHER_LOGIC_REV` block is an append-only "Bumped N -> N+1" series;
each stanza states what was true AT that rev and later stanzas
supersede it. Stale-sounding "exec" inside a past stanza is correctly
LEFT ALONE. The identical code snippet quoted elsewhere as CURRENT
code (e.g. under a "GUEST read (current boot launcher):" header) IS in
scope. Header framing, not wording, decides whether an "exec" mention
is historical or a live claim.

**Where emitted bytes live**: `build-guest-image.sh`'s
`emit_boot_launcher` heredoc is the only launcher-byte surface, so
`LAUNCHER_LOGIC_REV` need not bump for comment edits elsewhere. But a
provisioner heredoc that writes `mkosi.conf` also changes
generated-recipe bytes when its comments are edited (harmless: mkosi
ignores `#` lines, and image identity hashes only the bake config
files + repo name, never the recipe) — verify heredoc boundaries
before calling a comment edit "host-side only".
