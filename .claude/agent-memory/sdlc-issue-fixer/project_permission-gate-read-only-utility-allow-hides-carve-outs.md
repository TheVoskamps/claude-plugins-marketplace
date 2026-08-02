---
name: permission-gate-read-only-utility-allow-hides-carve-outs
description: In the guardrails permission-gate, `cat`/`head`/`grep` ALLOW for any contained-or-carved-out path via the read-only-utility terminal, so a cat-based assertion can never prove a new READ carve-out works — probe with `less` (DEFER terminal) or the Read tool.
metadata:
  type: project
---

The gate has two bash read tracks with **different terminals** for the
same containment verdict:

- `classifyReadOnlyUtility` (`cat`, `head`, `grep`, …) → terminal
  **ALLOW** for any operand that is contained *or* lands in any
  carve-out (`~/.claude`, the whole harness `/tmp/claude-<uid>` prefix).
- `classifyPathReader` (`less`, `more`, `od`, `xxd`, …) → terminal
  **DEFER**.

So `cat <path>` already returns ALLOW for paths a new read carve-out
has nothing to do with. A test asserting `cat <new-carve-out-path>` is
ALLOW passes identically before and after the carve-out exists.

**Why it matters:** on #193 / PR #208 the bundled-skills read carve-out
had to be probed with `less` and the `Read` file tool to show anything
at all; the negate-check (disabling the new branch) failed exactly
those assertions and left every `cat` assertion green. In the same
suite the pre-existing shape-miss test deliberately asserts only "must
not deny/ask" for bash, precisely because of this terminal — don't
"tighten" it to an exact DEFER without checking which track the program
takes.

**How to apply:** when adding or verifying a READ-side carve-out in
`engine_b_containment.go` / `classify_files.go`, exercise it with the
`Read` tool and with `less`; use `cat`/`head` only for the weaker
"inside the prefix, therefore never denied/escalated" claim. Pair with
the developer-side negate-check discipline (temporarily falsify the new
condition and count the failures) — a single failure where you expected
many means the test is thinner than it looks.

Related: [[pin-a-specs-empirical-premise-with-a-live-test]].
