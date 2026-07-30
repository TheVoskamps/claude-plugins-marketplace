---
name: prose-is-not-the-read-contract
description: before flagging a doc-trim PR as breaking consumers, check whether the reader contract explicitly excludes prose — skills/lib/repo-config.md says the generated file's prose "is not part of the read contract"
metadata:
  type: reference
---

Trim-the-generated-prose PRs in the `issues` plugin look risky ("does
a reader depend on this text?"), but `plugins/issues/skills/lib/
repo-config.md` → "What the file looks like" settles it in one read:

> The prose is for humans reading the file directly; it is not part
> of the read contract.

Readers parse only the YAML front-matter and the column-0
tracker-metadata block. So a body-prose trim can only break a
**human** or a **cross-reference**, never a parse.

**What to verify instead**, in this order:

1. `diff` the front-matter + metadata block old vs new (extract both
   with `git show <ref>:<path>` into `.claude/tmp/`) — a trim PR that
   claims "front-matter byte-for-byte unchanged" is cheap to confirm.
2. Grep for cross-references *into* the removed prose sections by
   name (e.g. `grep -rn 'fields\.\*\.default' plugins/`) — the
   dangling-pointer class is the real risk, not the parse.
3. Confirm each *new* pointer resolves: grep the target's `^#`
   headings per [[verify-doc-cross-reference-headings]], and confirm a
   `/plugin:skill` pointer against `plugin.json`'s `"name"` plus the
   skill's own `name:` front-matter.

**Also note:** the generated file's `skills/lib/...` paths are
plugin-internal and don't resolve from a consumer repo — but that
convention predates any given trim PR (check `git show
origin/main:<template>`), so it is not that PR's regression.
