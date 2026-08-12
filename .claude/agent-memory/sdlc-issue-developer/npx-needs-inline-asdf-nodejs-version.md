---
name: npx-needs-inline-asdf-nodejs-version
description: Bare `npx markdownlint-cli2` fails with "No version is set for command npx" in a subagent worktree; prefix the call with ASDF_NODEJS_VERSION= rather than running `asdf set`
metadata:
  type: feedback
---

In an `isolation: worktree` subagent, a bare `npx markdownlint-cli2 …`
does not run. asdf answers:

```text
No version is set for command npx
Consider adding one of the following versions in your config file at
<worktree>/.tool-versions
nodejs 26.5.0
```

The worktree has no `.tool-versions` — it is gitignored, so it lives
in the primary clone and does not come along. The obvious repair,
`asdf set nodejs 26.5.0`, is refused by the permission gate when
combined with anything else on the line, and writing a `.tool-versions`
into the worktree is a stray file in the diff's blast radius.

**Why:** the lint step is mandatory on every Markdown-touching PR in
this repo, so a subagent that reads this failure as "markdownlint is
not available" either skips the lint or escalates for an install that
is forbidden anyway.

**How to apply:** prefix the call with the version asdf itself
suggested, one command, no shell state:

```bash
ASDF_NODEJS_VERSION=26.5.0 npx markdownlint-cli2 <file>…
```

Take the version number from asdf's own error output rather than
pinning one here — it moves. Related: [[feedback_heredoc-commit-sandbox-gate]]
for the sibling "the gate refuses the compound form, use the plain one"
shape.
