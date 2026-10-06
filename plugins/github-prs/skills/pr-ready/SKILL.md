---
name: pr-ready
description: Mark a draft GitHub pull request as ready for review (draft -> ready).
---

# PR Ready

Flip a draft GitHub pull request into the ready-for-review state. A
draft PR cannot be auto-merged, so the flip is the point at which a PR
becomes mergeable; keep a PR draft until it is meant to be.

## Invocation

```text
/pr-ready <PR>
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.

## Execution

Run the bundled script, spelled as a bare name:

```bash
pr-ready <PR>
```

The script flips the PR, then re-reads it. A PR that is already ready
is left as it is — `gh` warns about it on stderr and succeeds — so the
script is safe to run more than once.

## Output and exit status

- **Exit 0** — the re-read shows the PR ready for review. Stdout is one
  line, `PR <PR> is ready for review`; report it back.
- **Exit 1** — the flip did not land: the re-read still shows a draft.
  Stderr says so; report it.
- **Exit 2** — a usage error; nothing was sent to GitHub.
- **Exit 3** — the `gh` call failed, and gh's own error is on stderr
  above the script's line. Surface it verbatim.
