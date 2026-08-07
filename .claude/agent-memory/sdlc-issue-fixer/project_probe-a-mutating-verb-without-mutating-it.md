---
name: probe-a-mutating-verb-without-mutating-it
description: To measure how a CLI parses a flag on a verb that publishes, make the FLAG PARSE fail (an invalid typed value) rather than relying on a later error — a cluster can consume the operand you were counting on to abort, and `gh gist create -pd x.md` reaches "Creating gist..." from stdin.
metadata:
  type: project
---

Measuring a parser's real grammar means running the real tool, and on a
gate PR the verb under measurement is usually one that PUBLISHES. The
safe probe is one whose **flag parse** fails, because flag parsing runs
before anything leaves the machine. Giving a bool an unparseable value
does it and is self-documenting: `gh gist create -p=zzz f.md` answers
`invalid argument "zzz" for "-p, --public" flag`, naming the flag pflag
handed the value to, which is the whole question. `-wp=zzz` names
`--public` and `-pw=zzz` names `--web`, settling that the `=` binds to
the shorthand immediately before it.

**Why:** the obvious alternative — let the parse succeed and rely on a
nonexistent file operand to abort — is not safe, and #229 round 6 proved
it live. `gh gist create -pd /nonexistent/zzz.md` printed
`- Creating gist...`: pflag read `p` as the bool `--public`, then `-d`
(`--desc`) took the *operand* as its value, leaving zero file operands,
and `gh gist create` falls back to STDIN when it has none. The abort I
was counting on had been eaten by the cluster. Only an empty stdin (the
Bash tool's) stopped it, with `a gist file cannot be blank`; a populated
stdin would have published a PUBLIC gist. `gh gist list` came back empty,
which is how that was settled rather than assumed.

**How to apply:** when a probe must touch a publishing verb, (1) pick an
invalid TYPED value so the failure is in the parser, (2) never let a
probe reach a state where a stdin-defaulting verb has no operand — check
the verb's own `Args`/`RunE` for that fallback first — and (3) after any
probe that got further than expected, read the remote state back
(`gh gist list`, `gh release list`) rather than inferring from the error
text. Report the near-miss; it is usually the same mechanism the fix is
about, and here it became a test row.

Related: [[help-output-is-not-the-accepted-grammar]],
[[verify-a-predicted-verdict-before-implementing-it]],
[[a-parity-fix-moves-verdicts-in-every-direction]].
