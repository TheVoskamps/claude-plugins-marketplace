---
name: cmdsub-strips-trailing-newlines-probe-emitters
description: A value fetched via value="$(yq …)" loses ALL trailing newlines while sibling paths (Python shlex.quote, direct eval assignment) preserve them — probe every emitter of operator-supplied values with a trailing-\n fixture and od -c before trusting a "byte-exact round-trip" claim.
metadata:
  type: reference
---

PR #243 (claude-vm `env:`) documented, on several surfaces, that `env.set`
values round-trip byte-exact — and its hostile-value tests proved spaces,
quotes, backticks and embedded newlines do. Trailing newlines do not, on
exactly one of the three paths: `claude_vm_resolve_boot_env` captures the
value with `value="$(claude_vm_env_set_value …)"`, and command substitution
strips every trailing `\n`. The bake path (JSON → Python `shlex.quote`) and
the `env.copy` path (`eval "value=\${NAME:-}"`, a direct assignment)
both preserve them, so the same literal differs by tier — a silent
mutation the feature's own CLAUDE.md paragraph names as the bug class it
exists to prevent.

**How to apply:** when a PR claims values round-trip exactly through a
shell emitter, feed it a fixture whose value ends in `\n` (YAML `X: "a\nb\n"`
or a block scalar `X: |`) and read the emission with `od -c`. Beware YAML
line folding in printf-built fixtures: `printf '… "a\n" …'` folds into a
space — write the escape as literal backslash-n bytes in the file. The
correct fix shape is "strip exactly the one newline yq appends"
(sentinel capture: `v="$(cmd; printf x)"; v="${v%x}"; v="${v%$'\n'}"`),
never strip-all. Related: [[verify-bash-regex-in-real-bash]] — same
"run it, don't reason about it" discipline. Also from the same review:
Python `re.match(r"^…$")` accepts a trailing newline (`$` matches before
final `\n`); demand `re.fullmatch`/`\Z` in name-validation rechecks.
