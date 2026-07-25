---
name: exec-prose-sweep-two-senses
description: claude-vm "exec" prose sweep (PR #180) has TWO senses — launcher-execs-claude (stale) vs guest-runs-RO-binary (provenance); resolved extinct at 6916ea4 via a token-exhaustive hand-classified audit
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

**Resolution**: extinct as of commit `6916ea4` (round 10), which
abandoned pattern greps and hand-classified EVERY occurrence of the
token "exec" in the plugin. Pattern-shaped greps failed in rounds 1-9
because real prose violates the pattern ("before claude execs", "execs
the RO-mounted binary" — object before the verb, object not claude).

**How to apply / the method that finally worked**: `grep -rniE exec`
over the WHOLE plugin, plus `grep -rc` over every file so the zero-hit
files are proven zero, then classify EVERY hit by hand into
(stale-current-behavior | negative assertion | historical/retrospective
| genuine exec). Never trust a needle-shaped grep, and never trust a
commit's own extinction claim — it was falsely asserted twice here.

**Changelog-stanza boundary rule**: `build-guest-image.sh`'s
`LAUNCHER_LOGIC_REV` block is an append-only "Bumped N -> N+1" series;
each stanza states what was true AT that rev and later stanzas
supersede it (the 16→17 stanza's "a nonzero exit `exec`s a LOGIN SHELL"
is corrected by 18→19). Stale-sounding "exec" inside those stanzas
(:108, :119-124) is correctly LEFT ALONE. The identical code snippet in
`lib/config.sh`'s `quote_args` doc WAS in scope, because it sat under a
"GUEST read (build-guest-image.sh boot launcher):" header presenting it
as CURRENT code. Header framing, not wording, decides.

**Where emitted bytes live**: `build-guest-image.sh`'s
`emit_boot_launcher` heredoc is the only launcher-byte surface, so
`LAUNCHER_LOGIC_REV` need not bump for comment edits elsewhere. But
`provisioners/podman-mkosi.sh` lines ~508-605 are a heredoc writing
`mkosi.conf` — comments edited there DO change generated-recipe bytes
(harmless: mkosi ignores `#` lines, and image identity hashes only the
bake config files + repo name, never the recipe). Verify heredoc
boundaries before calling such a comment edit "host-side only".
