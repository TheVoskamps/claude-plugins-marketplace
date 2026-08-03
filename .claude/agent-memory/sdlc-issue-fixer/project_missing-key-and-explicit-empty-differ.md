---
name: missing-key-and-explicit-empty-differ
description: "Can this field be empty?" has two different answers — a MISSING key and an explicit empty string reach the emitter by different paths, and in yq's @tsv an unguarded .key renders a missing key as the literal string "null" while an explicit "" gives a genuinely empty field; probe both before calling a case impossible
metadata:
  type: project
---

When asked whether a downstream reader can ever see an empty field,
the reachability question splits in two and the two halves can have
opposite answers. Probe **both** — a missing key and an explicit empty
value — against the real emitter before writing "this cannot happen".

**Measured on claude-vm's yq `@tsv` emitters (PR #228).** With
`[(.name // ""), (.repo // ""), (.key_url // "")] | @tsv`, every
absent key normalizes to a genuinely empty field, so
`apt_sources: [{name: nr, key_url: …}]` really does emit
`nr<TAB><TAB>…`. But `claude_vm_mount_specs` spells its middle field
as a bare `.tag` with no `// ""` guard, and there a **missing** `tag:`
renders the literal four-character string `null`, while an explicit
`tag: ""` renders empty. So the same "middle field empty?" question is
answered *no* for the omitted key and *yes* for the explicit one, in
one and the same emitter. Answering from the omitted-key case alone
would have graded the mounts site "unreachable".

`@tsv` is otherwise well-behaved as a producer: it always writes every
separator (an N-element array yields N-1 tabs), and it escapes an
embedded tab or newline in a value, so a record can never carry a stray
literal separator.

**How to apply.** One throwaway YAML with all the shapes side by side
(missing key, explicit `""`, fully populated) piped through the real
accessor and rendered with `sed -n l` settles it in one command — note
that macOS `cat -A` does not exist, so `sed -n l` or `od -c` is the
portable way to see the tabs. Do this before writing any "genuinely
impossible today" line into a comment, commit message, or PR body: the
claim is falsifiable in seconds and a reviewer will falsify it. Related:
[[verify-a-predicted-verdict-before-implementing-it]] (measure the row,
don't predict it) and [[flagscan-value-flag-swallows-path-operand]]
(a mis-modelled input class read from the wrong side).
