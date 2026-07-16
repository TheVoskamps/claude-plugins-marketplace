---
name: mikefarah-yq-unique-does-not-sort
description: mikefarah yq's `unique` de-dupes but preserves first-seen order; it does NOT sort. For an order-insensitive canonical form (hashing), you must `unique | sort`.
metadata:
  type: feedback
---

In mikefarah yq (the Go v4 build this repo uses), `unique` removes
duplicates but **preserves first-seen order** — it does NOT sort. This
bit me building the issue #105 bake-hash: `packages.bake: [git, jq]` and
`[jq, git]` are the same set but hashed differently because
`.packages.bake // [] | unique` left them in input order. The fix is
`unique | sort` (or `sort | unique`) whenever the goal is an
order-INSENSITIVE canonical form.

**Why:** for cache keys / content hashes, cosmetic differences (list
order, duplicate entries) must not fork the cache. `unique` alone
satisfies de-dup but not order-normalization; both are needed.

**How to apply:** any time you canonicalize a YAML list for hashing or
byte-stable comparison with mikefarah yq, use `unique | sort` for
scalars and `sort_by(<key>)` for object lists (e.g.
`.packages.apt_sources | map({...}) | sort_by(.name)`). Verify
order-insensitivity with a test that feeds the same set in two orders
and asserts equal hashes — the [[bash-scripts-test-under-bash-not-zsh]]
memory covers driving such tests under `bash -c`, not the tool's zsh.
Emit with `yq -o=json -I=0` for a compact, key-ordered (by the literal
object constructor), byte-stable string.
