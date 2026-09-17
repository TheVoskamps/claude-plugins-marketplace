# Code Style — this repo

## For Authors

## For Authors and Checkers

### A Markdown code file's frontmatter `description` matches its body

Every `SKILL.md` and agent definition the diff touches has a
frontmatter `description` that still describes the body as the diff
leaves it. That field is the file's doc comment: no Markdown code file
in this repo carries a TSDoc-style comment, so a sweep for `//` or
`/** */` finds nothing and establishes nothing about the file. An
`<!-- -->` line a skill or agent body emits as a literal marker is
code rather than a comment; any other `<!-- -->` line is a comment and
is graded as one.
