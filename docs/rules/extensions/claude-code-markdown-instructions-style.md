# Claude Code Markdown Instructions Style — this repo

## For Authors

## For Authors and Checkers

### Markdown lints clean under `markdownlint-cli2` run from the worktree root

Every Markdown file the diff touches passes `markdownlint-cli2 <file>…`,
run as the binary on `PATH` from the worktree root so
`.markdownlint.jsonc` applies. A `markdownlint-cli2` absent from `PATH`
is a stop-and-report, never an install.

`MD041/first-line-heading/first-line-h1` on a `SKILL.md` whose body
opens with an instruction rather than an H1 is not a violation: the
body is a prompt, and an H1 changes the payload the model receives.
Both openings are in use, so run the linter rather than predicting the
hit. A diff that edits such a file re-lints the file's base and
introduces no error class the base did not already report.

### A `SKILL.md` or agent definition's frontmatter `description` matches its body

Every `SKILL.md` and agent definition the diff touches has a
frontmatter `description` that still describes the body as the diff
leaves it. The frontmatter is part of the instruction file: the
harness loads the `description` to decide when to invoke the skill or
spawn the agent, before the body is ever read, so a `description` the
body has outgrown routes work by a contract the file no longer keeps.
