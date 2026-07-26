---
name: git-add-N-does-not-preserve-content
description: git add -N (intent-to-add) only records the path, not the blob; git checkout -- <file> after a subsequent delete restores an empty file, not the original content — verified in a scratch repo
metadata:
  type: reference
---

When designing an "undo via git checkout" mechanism for an untracked
file that is about to be deleted, `git add -N <file>` (intent-to-add)
is not sufficient. It stages the path but not the content, so after
`rm <file>` a subsequent `git checkout -- <file>` succeeds with no
error but restores a zero-byte file — the original content is gone.

Verified in a throwaway scratch repo (issue #184 / PR #185 review
fix): `git add -N untracked.md` then `rm untracked.md` then
`git checkout -- untracked.md` left the file present but empty
(`wc -c` = 0).

A full `git add <file>` (not `-N`) stages the actual blob content in
the index. After that, `rm <file>` then `git checkout -- <file>`
restores the exact original content — confirmed by content comparison
in the same scratch test.

**How to apply:** any agent-definition or skill fix that proposes
staging an untracked file purely to make its deletion "undoable" must
use a full `git add`, never `git add -N`, or the undo claim is false
in exactly the same way the original bug being fixed was false. Always
verify such git-mechanics claims in a real scratch repo before writing
them into a skill doc — do not trust recalled git behavior for a
load-bearing correctness claim.
