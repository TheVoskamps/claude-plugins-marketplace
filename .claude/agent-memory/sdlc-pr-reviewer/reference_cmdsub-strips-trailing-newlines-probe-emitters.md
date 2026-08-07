---
name: cmdsub-strips-trailing-newlines-probe-emitters
description: A "values round-trip byte-exact" claim needs a trailing-newline fixture read with od -c on EVERY emitter — command substitution strips all trailing newlines while shlex.quote and direct-assignment paths preserve them, so the same literal can differ per path.
metadata:
  type: reference
---

A PR that claims operator-supplied values round-trip byte-exact through
a shell emitter is not tested by hostile-value fixtures alone. Spaces,
quotes, backticks and *embedded* newlines survive nearly every path;
**trailing** newlines do not survive a `value="$(cmd …)"` capture, because
command substitution strips all of them. Sibling paths — a JSON value run
through Python `shlex.quote`, or a direct `eval "value=\${NAME:-}"`
assignment — preserve them. So a feature with several emitters can ship
the same literal as different bytes depending on which path carried it,
which is the silent-mutation class such features usually exist to prevent.

**How to apply:** feed every emitter a fixture whose value ends in `\n`
(YAML `X: "a\nb\n"`, or a block scalar `X: |`) and read the emission with
`od -c` rather than by eye. Beware YAML line folding when building the
fixture with `printf`: `printf '… "a\n" …'` folds into a space — write
the escape as literal backslash-n bytes in the file. The correct fix
shape is "strip exactly the one newline the emitter appends", via a
sentinel capture (`v="$(cmd; printf x)"; v="${v%x}"; v="${v%$'\n'}"`),
never a strip-all.

The same trailing-newline blind spot appears in name validation: Python
`re.match(r"^…$")` accepts a trailing newline, since `$` matches before a
final `\n`. Demand `re.fullmatch` or `\Z`.

Related: [[verify-bash-regex-in-real-bash]] — the same "run it, don't
reason about it" discipline.
