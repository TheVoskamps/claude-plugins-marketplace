# Working in plugins/guardrails

**Who reads this and when:** any agent about to change how the
permission gate is packaged, or what verdict it returns. Read it before
the first edit.

Gate *classifier* behavior is owned by
`plugins/guardrails/hooks/permission-gate/README.md`, and no other
plugin describes it. This file covers only what a change there drags
along with it.

## A packaging change sweeps claude-vm

The gate ships as prebuilt, committed binaries under
`hooks/bin/<goos>-<goarch>/`, selected at run time by `uname`. That
*shape* decides what a claude-vm bake file's `packages:` list must
contain, so it is mirrored in `plugins/claude-vm/`'s payload README, its
bake example, and its skill. A PR that changes the shape — the set of
`<goos>-<goarch>` directories, the selection or fail-closed logic in
`hooks/hooks.json`, or the gate's build recipe — updates those surfaces
and bumps both plugins' versions.

Rebuilding the committed binaries in place mirrors nothing and fires no
claude-vm sweep. Every classifier-change PR touches `hooks/bin/`, so
treating the path itself as the trigger would demand a no-op edit on
every one of them.

## A verdict change sweeps the readers bounded to it

Each `/docs` surface that names a verdict is bounded to one reader, so
sweep by grepping what it names rather than by opening the files this
list happens to mention:

- `docs/guardrails-verification-playbook.md` names verdicts as the
  **controls a probe needs**. A verdict change that moves a control row
  updates it; grep it for `deny`, `allow`, `defer` and `ask`.
- `docs/agent-tooling-notes.md` names them **for the agent being
  denied**: what a primary-clone read comes back as, and the routes that
  reach the wrong bytes with no deny at all. A change that opens or
  closes one of those routes updates it — and so does a change to the
  `PreToolUse` matcher, which is quoted verbatim there and twice in the
  gate README, so sweep it by grepping the matcher string.
- `docs/verification-playbook.md` names one verdict only, to keep a lint
  baselining technique runnable.
- `plugins/guardrails/rules/scratch-file-location.md` names verdicts
  only where they decide **which destination a scratch file goes to**. A
  verdict change that leaves that choice unchanged needs no edit there.

`.claude/agent-memory/` is deliberately absent from that last list: the
tree is gitignored, lives only in a throwaway worktree, and the session
inbox its entries reach dies with the session, so nothing there survives
to be falsified. Such a note reaches the repo only once a curator
transfers it into `CLAUDE.md` or `/docs` — grep those for the gate's own
message fragments ("not all static literals", "resolves outside the
current repository", "cannot resolve statically") whenever a verdict
changes.

## What a verdict looks like on the wire is a different axis

Which `permissionDecision` values the harness accepts, and that a hook
abstains by omitting the field rather than emitting the literal
`"defer"`, binds every PreToolUse hook in this marketplace — so it lives
in `docs/hook-event-notes.md`, and the gate README points there. A
rebucketing PR touches none of it; a PR that changes how a bucket is
spelled on stdout touches that file, the gate README, and the
playbook's probe-reading note together.
