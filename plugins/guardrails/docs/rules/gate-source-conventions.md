# Gate source conventions

**Who reads this and when:** any agent writing or reviewing a Go comment
or a `Reason` string under `plugins/guardrails/hooks/permission-gate/`.

## A comment states its rule in place

A Go comment in the gate states its invariant where it stands. It
never points the reader at an issue, a PR, a README or a rules file
for the rule: a pointer states no invariant, makes the reader fetch
something to learn it, and rots. `git blame` yields provenance on
demand. Where a pointer carried real reasoning, restate the reasoning
inline.

A comment describes the gate, not the harness around it. Justifying a
rule by a harness behavior this repo neither ships nor tests lets the
comment go false with no line of the package changing, and once the
stale claim is deleted the rule looks unmotivated. State what the gate
decides and what it sends the caller to do instead.

## A `Reason` is actionable on its own

A `Reason` — a deny, an ask, or a `deferJudgment` analysis — carries
no issue pointer. It reaches a blocked agent and, through the
evolution log, whoever tunes the evaluator; an issue number tells
neither what to do. `trackerRefInReason`
(`TestRemediationReasonsAreActionable`) asserts this over the emitted
text.

A `Reason` cites no instruction file guardrails does not own. A
pointer into `~/.claude/rules/` or another repository's rules resolves
against configuration a machine that installed this plugin need not
have, worded by someone else. State the constraint and the call that
satisfies it inline and stop there.

Two names are sanctioned anyway, because each is the remediation
itself rather than prose someone else worded:

- An executable the caller is sent to run, named by path, such as the
  wrapper the naked-`gh` deny names.
- The operator's config file, `~/.config/guardrails/config.yml`, whose
  schema `operatorCarveOutDocument` owns and whose location the gate
  alone fixes. Spell it from `~`, so no `Reason` carries the host's
  absolute home path.

No test guards the instruction-file rule, so it holds by inspection
whenever a `Reason` is written.
