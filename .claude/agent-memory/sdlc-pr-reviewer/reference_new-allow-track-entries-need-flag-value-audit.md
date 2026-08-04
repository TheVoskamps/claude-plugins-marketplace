---
name: new-allow-track-entries-need-flag-value-audit
description: When a guardrails PR adds a program to the read-only ALLOW table or gives one an operandsFn, audit every flag whose VALUE is a file the program reads (-f/--file, -X, --from-file) and every subcommand flag that changes what the command prints (gh auth status --show-token) — a widening PR's regressions hide in flag values, not in operands.
metadata:
  type: reference
---

Two independent Critical/High regressions on PR #227 had the same shape: the
PR widened an ALLOW and the widening leaked through a **flag value**, not
through an operand. Operand rows all had tests; flag-value rows had none.

**The two mechanisms, both worth a probe row on every classifier PR:**

1. **A new `operandsFn` that consumes a flag's value.** `sed`/`awk`/`grep`
   got a read-track operand grammar so the SCRIPT positional stops being
   tested as a path. It also consumes `-f`/`--file`'s value — but that value
   is a file the program genuinely READS (grep's pattern file, sed's script
   file, awk's program file), so `grep -f /etc/passwd README.md` went
   `main=deny -> pr=allow`. `-e`'s value is a pattern and is correctly
   consumed; `-f`'s is a path and must not be. Prove the read with a two-file
   sandbox: `grep -f pat.txt hay.txt` prints the match.
2. **A new table entry with NO `operandsFn`.** `diff` joined
   `readOnlyUtilities` so `diff <(a) <(b)` could allow. With no grammar it
   falls to `pathOperands`, which skips every leading-DASH token, so the
   GLUED spellings of its file-valued flags (`-X/etc/passwd`,
   `--exclude-from=`, `--from-file=`, `-S/…`) skip containment while the
   SEPARATE-token spelling still denies. Same command, two verdicts by
   spelling — the exact inconsistency such PRs exist to remove.

**Probe both spellings of every value flag, always.** `-Xfile` vs `-X file`
vs `--exclude-from=file` gave three different verdicts on one binary. Some
glued forms are pre-existing holes on main (`grep --file=`, `awk --file=`) —
say which are the PR's regression and which the fix should sweep anyway.

**A verb-level ALLOW arm must inspect flags.** `classifyGh`'s new
`case "status":` returns `allow` for the whole subcommand, so
`gh auth status --show-token` (a documented `gh` flag: "Display the auth
token", present in gh 2.96.0) auto-dumps the live credential; the arm's own
comment claimed it kept "every credential-printing verb on the escalation
track by construction". Check `<tool> <verb> --help` for a flag that changes
WHAT IS PRINTED before accepting any new verb allow. Do NOT run the probe
against the real credential (`--json hosts` may carry the token) — read the
help text, then probe the gate binary with a synthetic event instead.

**How to apply:** for every program a classifier PR adds or re-grammars, list
its flags whose value is a path or which change the output's sensitivity, and
put one `pr=/main=` probe row on each. Controls that make the row legible: the
same program with an ordinary escaping operand (must still deny) and the
substitution-free spelling.

Related: [[reference_flag-model-cannot-swallow-containment-operands]] (the
same `pathOperands` dash-skipping, seen from the other side),
[[reference_guardrails-binary-verification]].
