---
name: help-output-is-not-the-accepted-grammar
description: A finding that names ONE spelling a CLI accepts but never renders is a finding about the parser library, not about that spelling — read the library's parse loop, because the sibling cases can be containment holes rather than extra clicks.
metadata:
  type: project
---

A flag whitelist transcribed from `<tool> <verb> --help` is only as
complete as the help renderer. When a review says "spelling X is
accepted but unmodelled", the class is the LIBRARY's grammar, and the
cheapest way to enumerate it is to read the parse loop rather than
re-read the help.

On #232 the finding was `-h`. Reading pflag's `parseSingleShortArg`
(`gh api "repos/spf13/pflag/contents/flag.go?ref=v1.0.10"`) produced
three facts the help could never show, and only the first was the
finding:

- an unregistered `h` shorthand returns `f.usage()` + `ErrHelp`, so
  `-h` works on every gh verb — **and the mechanism is pflag, not
  cobra**, whose `InitDefaultHelpFlag` skips it because gh's root
  already registers a persistent `--help`;
- `if len(shorthands) > 2 && shorthands[1] == '='` strips the `=` after
  a shorthand, which **getopt does not** — so a getopt-shaped extractor
  reads `-F=/etc/passwd` as the relative in-repo `=/etc/passwd` and the
  gate ALLOWED the exfil it was written to deny;
- the same rule ENDS the token, so `-p=f` is `--public=false` and a
  screen that keeps walking past the `=` reads a trailing `f` as
  `--filename` and eats the next operand out of the positional walk.

**Why:** the finding's own severity does not bound the class. `-h` was a
Low (one extra click, fail-safe); its sibling in the same parse function
was an allow-an-escaping-path hole, and no reviewer had asked about it.

**How to apply:** when fixing "tool accepts a spelling the model lacks",
fetch the parser's source at the version pinned in the tool's `go.mod`
(via `gh api ".../contents/<path>?ref=<tag>"`), and probe `-x=value` on
BOTH a value-taking and a bool shorthand. Confirm each spelling against
the real tool with a harmless probe — `-F=/nonexistent/x` reports the
path it opened, `-p=zzz` fails on ParseBool and proves the value is
really being parsed. Fixes to the two directions must land together:
adding the `=` stop to the flag screen alone would have opened the
operand-swallow. Related: [[negative-control-the-approved-snippet]],
[[verify-a-predicted-verdict-before-implementing-it]],
[[implement-the-findings-broader-rule]].
