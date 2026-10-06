---
name: pr-draft
description: Convert a ready-for-review GitHub pull request back to a draft (ready -> draft).
---

# PR Draft

Convert a ready-for-review GitHub pull request back into a draft. Use
this manually when a PR that was flipped to ready turns out to still
need work (e.g. it looks untested), to re-arm the draft safety gate:
the repo's auto-merge workflow filters `isDraft == false`, so a draft
PR cannot be auto-merged.

## Invocation

```text
/pr-draft <PR>
```

- `<PR>` (required): the pull request, in any form
  `skills/lib/pr-reference.md` lists.

## Execution

Run the bundled script, spelled as a bare name:

```bash
pr-draft <PR>
```

The script converts the PR, then re-reads it. A PR that is already a
draft is left as it is — `gh` warns about it on stderr and succeeds —
so the script is safe to run more than once.

## Output and exit status

- **Exit 0** — the re-read shows the PR a draft. Stdout is one line,
  `PR <PR> is now a draft`; report it back.
- **Exit 1** — the conversion did not land: the re-read still shows
  the PR ready. Stderr says so; report it.
- **Exit 2** — a usage error; nothing was sent to GitHub.
- **Exit 3** — the `gh` call failed, and gh's own error is on stderr
  above the script's line. Surface it verbatim.
