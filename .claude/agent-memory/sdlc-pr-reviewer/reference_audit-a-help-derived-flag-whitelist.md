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

**Machine-diff it — and get the table by RUNNING the package, not by parsing
it.** On #232 round 6 the conclusive route was: `git archive HEAD
plugins/guardrails/hooks/permission-gate | tar -x -C <repo>/.claude/tmp/<slug>/src`,
drop a throwaway `zz_dump_test.go` into the extracted package that marshals the
live table to JSON (`os.WriteFile(os.Getenv("DUMP_OUT"), …)`), and run
`DUMP_OUT=<path> go -C <extracted-pkg> test -run TestZZDump ./...`. That beats
the python-parses-Go recipe on the axis that decides the audit: the dump is the
table **after** the constructor runs, so a builder that merges inherited flags
in (`ghSpec` folding `-R`/`--repo`/`--help`/`-h` into all 26 specs) and shared
vars referenced by name (`ghBodyFileFlags`, `ghNotesFileFlags`) are already
resolved, where a source parse has to reproduce both by hand and silently
under-reports when it misses one. It is also the only form that can dump a
derived predicate (`readsLocalFiles()`). Use the extracted copy rather than the
worktree so the throwaway file never lands in the PR's tree.

Then for each pair run `<tool> <noun> <verb> --help` and diff. Both directions
are informative: gh-documented-but-unmodelled is a false ask,
modelled-but-undocumented is usually a harmless uniform merge (#232 folded
`-R`/`--repo` into the `gist` specs, which gh rejects — no consequence).

The same dump is what settles a **doc enumeration** of the table: derive the
per-flag verb sets and the positional/stdin members from the JSON and compare
them to the prose, rather than grading two prior rounds' reports against each
other. On #232 round 5 called the operand half exhaustive and it was missing
`gh release edit`; a dump-derived compare found it in one pass.

**The axis that actually matters is ARITY, not presence.** A bool mismodelled
as value-taking consumes the next token, and on a verb with file positionals
that is the one way such a walk can swallow a path OUT of containment. Split
the `ghSpec(valueFlags, boolFlags, …)` call by tracking brace depth and compare
each set against whether the help line carries a value-type word
(`-F, --body-file file` then the description). Expect one false positive class,
and know its cause: pflag's `UnquoteUsage` lifts a **backquoted word out of the
usage string** and renders it where the value type goes, so a BOOL reads as
value-taking. gh renders
`--succeed-on-no-caches --all   Return exit code 0…` because its usage ends
"in conjunction with `` `--all` ``". The tell is the same word appearing
un-backquoted in the description; the proof is the registration —
`gh api "repos/cli/cli/contents/pkg/cmd/cache/delete/delete.go?ref=v2.97.0"
--jq .content | base64 -d | grep BoolVar`. Read the source before filing an
arity finding.

A whole run of these parses cleanly with
`^\s{2,}(?:(-[A-Za-z]), )?(--[A-Za-z0-9-]+)(?: (\S+))?\s\s+\S`: the annotation
is ONE token separated by a single space, and the description always follows
two or more.

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
value-taking and a bool shorthand.

**Probe the parser through a READ-ONLY verb with an INVALID value.** Never run
the mutating verb the finding is about (`gh pr comment … -F=…` posts a comment
if the file happens to exist). Pick a read verb with a typed flag and give it
garbage: `gh pr list -L=abc` fails inside the same `parseSingleShortArg` and
the error QUOTES the value pflag extracted, which is the whole answer. On gh
2.97.0 the five rows settle every discrimination at once — `-L=abc` → `"abc"`
(stripped), `-L =abc` → `"=abc"` (separate token is literal), `--limit==abc` →
`"=abc"` (long keeps everything after the FIRST `=`), `-L=` → `"="` (under the
`len > 2` threshold), and `-sL=abc` → `-s` takes `"L=abc"` (a preceding
value-taking shorthand makes the `=` ordinary). Zero network, zero mutation,
and it beats quoting the PR's own measurement back at it.

Hidden flags are worth one search
(`gh api -X GET search/code -f q='MarkHidden repo:cli/cli path:pkg/cmd'` — none
of the 26 modelled pairs has one) and abbreviations are not a pflag feature
(`gh pr comment --bod x` → `unknown flag`).

**How to apply:** on any gate PR that adds or extends a per-verb/per-program
flag whitelist. Keep the audit scripts in `<repo>/.claude/tmp/<slug>/` and run
them with `python3 <script>` — they need no gate-awkward shell. Related:
[[new-allow-track-entries-need-flag-value-audit]] (the same table seen from the
value-is-a-path side), [[guardrails-binary-verification]].
