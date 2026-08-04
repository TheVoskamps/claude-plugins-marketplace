---
name: implement-the-findings-broader-rule
description: When a finding prescribes a rule broader than the real tool's behavior and the extra breadth is on the SAFE side, implement the finding's version and write the divergence into the code comment — do not silently narrow it to what the tool actually does
metadata:
  type: feedback
---

A finding sometimes spells a rule that is stricter than the underlying
tool's real semantics. If the extra strictness lands on the safe side of
the failure asymmetry, implement the finding's rule as written and state
in the code (and any doc that repeats it) that it is deliberately
broader than the tool, and why. Do not quietly narrow it to the
"technically correct" model.

**Why:** on PR #227 round 3 the review required `gh auth status` to
escalate on "any bundled short-flag cluster containing `t`". By pflag's
shorthand parsing that is wrong for one form — in `-ht` the `h`
(`--hostname`) takes the rest of the cluster as its value, so the `t` is
data, not `--show-token`. Implementing the narrow, parser-accurate model
would have contradicted the finding on an exotic spelling, invited
another round, and made the gate's correctness depend on the gate
modelling gh's cluster arity exactly. The asymmetry decides it: a missed
token print is a leaked credential, a spurious escalation is one click.
The shipped rule is therefore "only the exact `-a` and `-h` pass; every
glued or bundled short form escalates", and both the arm's comment and
the README say it is broader than gh's own parser and name `-ht` as the
case.

Note what the same asymmetry forbids: narrowing in the LAXER direction.
If a finding's letter would make the code *weaker* than reality
warrants, that is an escalation to the human, not a silent correction —
see [[finish-it-dont-defer-it]] for the sibling instinct on scope.

**How to apply:** when the finding's letter and the tool's behavior
disagree, ask which way the divergence fails. Safe-side → take the
finding, document the divergence at the point a future reader will
challenge it (the arm, not just the PR body). Lax-side or ambiguous →
report it rather than deciding. Either way, verify the tool's real
behavior first from its own help/source, not from priors, and never by
running the credential-printing command itself. Related:
[[negative-control-the-approved-snippet]].
