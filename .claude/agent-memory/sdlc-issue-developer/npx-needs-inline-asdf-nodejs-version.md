---
name: npx-needs-inline-asdf-nodejs-version
description: Bare `npx markdownlint-cli2` fails in a subagent worktree; prefix the call with both PATH="$HOME/.asdf/bin:$PATH" and ASDF_NODEJS_VERSION= rather than running `asdf set`
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
pinning one here — it moves.

**The `asdf: not found` variant.** Sometimes the shim fails differently:

```text
/Users/<user>/.asdf/shims/npx: line 8: exec: asdf: not found
```

`~/.asdf/shims` is on PATH but `~/.asdf/bin` is not, so the shim cannot
exec the `asdf` it dispatches through — and here `ASDF_NODEJS_VERSION`
alone does not help, because nothing gets far enough to read it. Two
traps follow. Asking asdf for the version is itself blocked: a bare
`ls ~/.asdf/installs/nodejs/` is refused as an out-of-repo read, and
`command -v node npx asdf; echo $PATH | …` is refused as too complex
for the worktree-containment check. Put `~/.asdf/bin` on PATH for the
one call instead, and ask asdf itself:

```bash
PATH="$HOME/.asdf/bin:$PATH" asdf current nodejs
PATH="$HOME/.asdf/bin:$PATH" ASDF_NODEJS_VERSION=<that version> npx markdownlint-cli2 <file>…
```

Related: [[feedback_heredoc-commit-sandbox-gate]] for the sibling
"the gate refuses the compound form, use the plain one" shape.
