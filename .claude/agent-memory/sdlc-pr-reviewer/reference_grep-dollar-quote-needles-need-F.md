---
name: grep-dollar-quote-needles-need-F
description: A grep needle containing $'...' silently under-matches as a regex; verify a "no X survives" sweep claim with grep -F or the claim looks true when it is false
metadata:
  type: reference
---

When verifying a PR's "no `X` survives anywhere in the code" sweep claim, and
the needle contains a shell `$'...'` ANSI-C quote, **run it through `grep -F`**.
The regex form under-matches, silently.

Measured on PR #228 (claude-vm TSV record splitting), against
`plugins/claude-vm/payload/test/config-test.sh`, which really does contain
`while IFS=$'\t' read -r tf_name tf_url; do` at line 2716:

- `grep -rn "IFS=\$'\\\\t' read" <file>` → **0 hits**
- `grep -rnF "IFS=\$'\\t' read" <file>` → **2 hits**
- `grep -rnF "IFS=\$'" <file>` → **2 hits**

The failure direction is the dangerous one: a zero-hit regex result reads as
"the sweep is complete", so a reviewer certifies a claim the code falsifies —
and in that PR it would also have hidden that the negative-control assertions
exist at all, which is separately load-bearing evidence.

Two layers of escaping stack here (the Bash tool's double-quoted string, then
the regex engine), so reasoning about how many backslashes survive is not
worth doing. Drop to the shortest distinctive `-F` needle instead
(`IFS=$'` sufficed) and read the hits.

Generalizes past `$'`: any needle carrying regex metacharacters —
`$`, `*`, `[`, `\` — is a candidate. When the claim under test is a
**negative** ("none survive"), the cost of a false zero is a wrong approve,
so prefer `-F` by default and only reach for a regex when the match genuinely
needs alternation.

Related: [[run-documented-grep-needles]] (a documented sweep needle is a
testable claim — run it at tip), [[sweep-artifacts-hide-in-line-wraps]]
(multi-token needles miss line-wrapped sites).
