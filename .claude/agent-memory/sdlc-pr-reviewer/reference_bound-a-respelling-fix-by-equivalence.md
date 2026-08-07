---
name: bound-a-respelling-fix-by-equivalence
description: To bound the blast radius of a fix that makes one spelling inherit another's verdict, assert PR(alias) == PR(canonical) over the tool's OWN complete alias table rather than eyeballing a main-vs-PR verdict diff — and close the case/prefix axes so the table is provably the whole spelling set.
metadata:
  type: reference
---

A fix that resolves an alias to its canonical spelling before classifying
moves rows in every direction at once, and the orchestrator will ask you
to "verify it is exactly that and nothing wider". A main-vs-PR verdict
diff answers the wrong question: it tells you WHICH rows moved, not
whether each landed where it should.

**The decisive check is an equivalence sweep.** For every alias spelling
the tool itself declares, crossed with operand suffixes that reach each
tier (bare, an escaping path, a contained path, the flag forms, the
publish flag), assert both:

- `PR(alias) == PR(canonical)` — the fix grants the canonical verdict
  and nothing else;
- `PR(canonical) == main(canonical)` — no canonical verdict moved as a
  side effect.

On #232 round 8 that was 2,184 pairs with **0** first-kind violations,
which settled "nothing wider" in one run. Every second-kind hit was an
intended containment/publish move, so the two assertions also separate
the alias work from the rest of the PR for free. Build the pair list
from the tool's alias table, not from the PR's table — otherwise you are
grading the fixer's enumeration with itself.

**Then close the axes a name-keyed table would miss**, or the table is
only *a* spelling set, not *the* spelling set. For gh 2.97.0, measured:
dispatch is case-SENSITIVE and there is NO prefix matching —
`gh gist CREATE x`, `gh gist crea x`, `gh gist nw x` each answer
`unknown command "…" for "gh gist"`, while `gh gist new x` dispatches.
So the cobra ALIASES blocks are the complete set and the gate's
fail-closed ask on a near-miss matches gh's own rejection.

**Trap: probe dispatch with a real invocation, not `--help`.**
`gh gist crea --help` exits **0** and prints `Work with GitHub gists.` —
the PARENT's help, because the subcommand was not found. Read the help
TEXT, or drop `--help` entirely; an rc-only reading says every bogus
spelling dispatches.

**The user-config alias mechanism is a separate, correctly-excluded
class.** `gh alias set` refuses any name that is "already a gh command
or extension" — verified for `secret`, `gist`, `pr`, `variable`,
`ruleset`, `api` and even the cobra alias `rs` — so a config alias can
never shadow a modelled noun. gh ships exactly one (`co: pr checkout`),
and both spellings ask. A brand-new name (`pub`) is accepted but needs
its own human click, since `gh alias set` itself asks. Probe all of this
inside a throwaway `GH_CONFIG_DIR=<repo>/.claude/tmp/...` — never the
user's `~/.config/gh`, which is outside the sandbox.

**Deny-tier `deny → allow` is safe only if the canonical spelling
already allowed on MAIN.** `gh secret ls` / `gh variable ls` were hitting
the secret-noun's blanket default-deny purely because `ls` is not
`list`; `gh secret list` and even `gh --repo o/r secret list` already
allowed on main's binary, so the move added no capability. Check the
canonical row on the OLD binary, including the foreign-target spelling —
that is the whole argument.

**gh parse facts measured this round** (useful, and each has been stated
wrongly in-tree at least once): `-pd <path>` does NOT error on a missing
`-d` value — `-d` eats the path and `gist create` falls back to stdin
and POSTs; only a trailing `-pd` errors. `-dp <path>` is `--desc p` and
reads the operand. `=` binds to the shorthand immediately before it
(`-wp=zzz` fails ParseBool naming `--public`, `-pw=zzz` naming `--web`).
`--desc --public` consumes the flag as a VALUE, so the gist is secret —
a `containsToken` scan over-asks there and a faithful pflag walk
correctly allows.

Related: [[audit-a-help-derived-flag-whitelist]],
[[guardrails-binary-verification]],
[[measure-the-quantifier-in-your-own-premise]].
