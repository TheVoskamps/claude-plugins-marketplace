---
name: prove-config-inheritance-chain-live
description: A nested config that "extends" a parent can silently no-op; prove the chain by flipping a value in the PARENT and watching it propagate to the child scope, plus a wrong-path run to show it fails closed — clearing violations alone proves nothing
metadata:
  type: project
---

When a nested config inherits from a parent — e.g.
`.claude/agent-memory/.markdownlint.jsonc` carrying
`"extends": "../../.markdownlint.jsonc"` — the obvious check, "the
violations I carved out disappeared", is **not** evidence the `extends`
resolved. Turning a rule off in the child works identically
whether the parent was merged in or silently dropped, and defaults like
markdownlint's `"default": true` are implicit anyway, so the parent's
own settings are invisible in the happy path.

**Why:** a wrong relative path is the actual failure mode, and it
degrades into exactly the observation you were about to accept as
success. The child's own keys still apply; only the inherited ones
vanish, and you cannot see inherited keys you never violate.

**How to apply:** the controls are all cheap.

1. **Propagation (positive).** Temporarily add a setting to the
   **parent** that would visibly change results in the child scope
   (here `"MD040": false` at the root), re-run in the child dir, and
   confirm the behavior changed. Then revert the parent and confirm
   `git status --porcelain <parent>` is empty — byte-identical to HEAD,
   not merely "looks right".
2. **Fail-closed (negative).** Point `extends` at a path that does not
   exist and re-run. markdownlint-cli2 v0.23.2 throws a visible
   `ENOENT` naming the resolved absolute path, so a typo'd chain fails
   loudly rather than silently. That absolute path in the error is also
   the fastest way to confirm how the relative path is being resolved
   (relative to the config file's own dir, not to cwd).
3. **A/B same content.** Put byte-identical probe content inside and
   outside the governed tree and diff the violation sets — this isolates
   exactly which rules the nested config changed and catches an
   over-broad carve-out. It also explains away rules that fire in
   *neither* location (an inherited setting doing nothing on your probe
   content) instead of misreading that as a chain failure.

Delete the probe files before committing and confirm with
`git status --porcelain`. See [[real-build-verification-not-unit-tests]]
for the same "exercise the real mechanism, don't assert it" instinct.
