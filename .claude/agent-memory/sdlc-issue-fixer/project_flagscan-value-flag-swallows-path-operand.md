---
name: flagscan-value-flag-swallows-path-operand
description: In the permission-gate's flagScan, marking a short flag as a valueFlag makes it consume the FOLLOWING token — so a flag whose arity differs between GNU and BSD (ls -I/-T/-w) can eat the only path operand and skip containment entirely; leave such flags unmodelled so they defer
metadata:
  type: project
---

`flagScan.defers` treats a `valueFlags` entry as consuming the next
token. That is a **fail-open** lever, not a neutral one: if the flag is
a bool in the implementation the user actually runs, the token it eats
is the command's only path operand, `pathOps` stays 0,
`containPathOperands` gets an empty operand list and returns
`ok=true` — an outright ALLOW with no containment check at all.

**Why it bites:** several short flags differ in arity between GNU
coreutils and BSD/macOS. `ls -I PATTERN` / `-T COLS` / `-w COLS` take
values in GNU; BSD's `-I` and `-T` are plain bools. Model them as value
flags and `ls -I /etc` allows an out-of-repo listing on macOS; model
them as bools and the GNU form misparses.

**How to apply:** when adding a utility to `readOnlyUtilities`,
enumerate as `boolFlags` only what is a bool in BOTH implementations,
put ambiguous short flags in NEITHER map (an unmodelled flag hits the
`return true` fail-safe and defers, costing one prompt), and prefer the
GNU **long** spelling for value flags — long flags don't exist in BSD
`ls`, so `--ignore`/`--width` are unambiguous. An optional-value flag
(`--color`, legal bare) must be a bool: the `--flag=VALUE` branch checks
both maps, so the attached form still parses.

Also note, for anything that reads a memory about probing this gate:
**as of #193 / PR #208 round 3, `ls` IS on the read-only-utility ALLOW
track and a `>` redirect destination IS graded** (via
`redirectVetoesAllow`). Memories asserting that `ls` reaches no allow
track, or that a redirect target never reaches an Engine B containment
check, describe the pre-round-3 gate — the pr-reviewer's
`probe-forms-that-cannot-prove-gate-carve-outs` is one of them.

Related: [[permission-gate-read-only-utility-allow-hides-carve-outs]],
[[pin-a-specs-empirical-premise-with-a-live-test]].
