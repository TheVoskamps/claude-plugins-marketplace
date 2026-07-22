---
name: mikefarah-yq-comma-expression-drops-branches
description: mikefarah yq's `.[] | (a), (b)` comma-expression can silently drop a branch's output across array elements when a later element's branch is empty. Wrap in `[(a), (b)] | .[]` instead.
metadata:
  type: feedback
---

Building issue #106's `claude_vm_apt_source_hosts` (deriving egress
hostnames from `packages.apt_sources` entries), a bare comma-expression
per array element —

```
.packages.apt_sources // [] | .[] | (.repo // ""), (.key_url // "")
```

— silently dropped `key_url` values from EARLIER array entries whenever a
LATER entry's `key_url` was empty. Confirmed empirically under yq v4.53.3
(mikefarah/Go build): a 2-entry config where entry 1 had both `repo` and
`key_url` set and entry 2 had only `repo` produced just 2 output lines
total (both `repo` lines), silently swallowing entry 1's `key_url` line —
not the expected 3 (or the "4 lines with an empty line for entry 2's
missing key_url" a comma-expression's per-branch semantics would suggest).

**Why:** unclear from the docs, but observed as a repeatable interaction
between yq's document-stream output (each comma branch becomes a document
in the stream) and per-`.[]`-iteration collapsing. Not investigated to a
root cause in the yq source — treat as an empirical trap, not a documented
behavior. Related to but distinct from [[mikefarah-yq-unique-does-not-sort]]
(a different footgun in the same tool).

**How to apply:** never emit multiple comma-separated expressions per
`.[]`-iterated array element when any might be legitimately empty. Wrap
the branches in an array constructor and flatten instead:

```
.packages.apt_sources // [] | .[] | [(.repo // ""), (.key_url // "")] | .[]
```

This emits one array per element (so an empty branch still contributes
its `""` placeholder) then flattens with a second `.[]`, which round-trips
every entry correctly — verified against the failing case above. Any time
you write a yq expression with a bare `,` inside a `.[]`-mapped pipe,
switch to this array-then-flatten form and add a test fixture where a
later element's branch is deliberately empty (the bug does not surface
with uniform, all-populated fixtures).
