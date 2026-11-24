# guardrails

- `plugins/guardrails/docs/rules/verdict-tiers.md` — read before adding a
  gate verdict or moving a call between verdicts. Kernel: tier
  membership is stated there and nowhere else, so read it rather than
  inferring a call's tier from a neighbouring arm.
- `plugins/guardrails/docs/rules/gate-source-conventions.md` — read
  before writing a Go comment or a `Reason` string in the permission
  gate. Kernel: state the rule in place, and never point at an issue, a
  README or a rules file guardrails does not own.
- `plugins/guardrails/docs/rules/guardrails-verification-playbook.md` —
  read before asserting what the permission gate does. Kernel: the gate
  ships policy inside a committed binary, so settle a verdict by
  replaying a synthetic event against that binary, never by reading the
  Go source.

- Policy ships inside the committed binaries under
  `plugins/guardrails/hooks/bin/<goos>-<goarch>/`. Any `.go` edit,
  comments included, means `golangci-lint fmt --diff`, then committing
  the source, then
  `plugins/guardrails/hooks/permission-gate/rebuild-binaries.sh` on the
  clean tree, then amending the rebuilt binaries into that same commit
  at git mode `100755`, checked with
  `git ls-files -s plugins/guardrails/hooks/bin/`.
- A packaging-shape change updates the `claude-vm` surfaces that mirror
  it and bumps both plugins. The shape is the `<goos>-<goarch>` set,
  the `hooks.json` selection and fail-closed logic, and the build recipe
  in `rebuild-binaries.sh`. Rebuilding the binaries in place is not one.
- A verdict change sweeps every surface that names one. Find them by
  grepping the repository for the verdict words `deny`, `allow`,
  `defer` and `ask`, the `hooks.json` matcher string, and the gate's
  message fragments, never by recalling which files named it last time.
- The `config.yml` schema is `operatorCarveOutDocument`.
