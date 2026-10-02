# Claude Code Markdown Instructions Style — this repo

## For Authors

## For Authors and Checkers

### A `SKILL.md` or agent definition's frontmatter `description` matches its body

Every `SKILL.md` and agent definition the diff touches has a
frontmatter `description` that still describes the body as the diff
leaves it. The frontmatter is part of the instruction file: the
harness loads the `description` to decide when to invoke the skill or
spawn the agent, before the body is ever read, so a `description` the
body has outgrown routes work by a contract the file no longer keeps.
