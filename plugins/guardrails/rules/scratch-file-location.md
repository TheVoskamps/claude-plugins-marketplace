# Scratch / Temporary File Location

Agent scratch, temporary, and throwaway files go under
**`<repo-root>/.claude/tmp/`** — never `/tmp/` (out of repo) and never
`.git/` (git internal state).

## The rule

When an agent needs somewhere to put a file that is not part of the
deliverable — a sandbox, a test fixture, an intermediate artifact, a
scratch buffer — it writes under `<repo-root>/.claude/tmp/`. In a
linked worktree that root is `$(git rev-parse --show-toplevel)`, so the
destination is `$(git rev-parse --show-toplevel)/.claude/tmp/`.

- ✅ `<repo-root>/.claude/tmp/issue-30-scratch/foo.json`
- ❌ `/tmp/foo.json` — out of repo; boundaries can't be enforced and
  the artifact escapes inspection.
- ❌ `.git/foo.json` (or anywhere under `.git/`) — git internal state.
  The permission-gate denies it outright (issue #125, broadened in #35).

## Why this location

`/**/tmp/` is **already gitignored repo-wide** (see the repo's
`.gitignore`), so `<repo-root>/.claude/tmp/` is an untracked, in-repo
location:

- **In-repo** → the permission-gate's containment check treats it as
  `contained`, so the write is allowed (it defers to the normal
  pipeline) rather than blocked as a cross-repo (#148) or
  worktree-escape (#127) escape.
- **Gitignored** → scratch artifacts never get committed and never
  pollute a diff.
- **Inspectable on failure** → because it lives under the repo, a
  failed run leaves its sandbox where it can be examined, rather than
  in a system temp dir outside the boundary.

No new `.gitignore` line is required; the `/**/tmp/` rule already
covers `.claude/tmp/` at any depth. Verify with:

```sh
git check-ignore -v .claude/tmp/x
```

## Why the permission-gate deny messages point here

A guardrail that only forbids invites a workaround; a guardrail that
prescribes prevents one. The permission-gate's containment denies
(#127, #148) used to tell the agent only what it may *not* do. Faced
with an open-ended denial of a scratch write, the model improvises its
own landing spot — and a plausible-but-wrong improvisation is to write
under `.git/` purely because that directory is gitignored and in-repo,
so it slips past containment. The deny induced the bad write.

As of issue #30, the write/edit containment-escape denies name this
canonical destination and explicitly warn against `.git/`, so the
feedback prescribes the correct alternative instead of leaving it to
the model's discretion. The policy itself is compiled into the
permission-gate binary (see `hooks/permission-gate/classify_files.go`);
this document records the convention the deny messages prescribe.
