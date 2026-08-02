---
name: rebase-continue-editor-gate
description: Both env-prefix (GIT_EDITOR=true git ...) and config-injection (git -c core.editor=true ...) forms are blocked by the permission gate, so drive a conflicted rebase with `git commit --no-edit` then a bare `git rebase --continue` — then strip the `# Conflicts:` blocks that workaround bakes into every resolved commit's message
metadata:
  type: feedback
---

To finish a conflicted rebase step without an interactive editor, stage
the resolution, run a bare `git commit --no-edit`, then a bare
`git rebase --continue`. The commit reuses the replayed commit's own
message, and `--continue` then has nothing left to prompt for.

**Why:** the two obvious ways to suppress the editor are both refused
here, each by its own gate with its own message:

- `GIT_EDITOR=true git rebase --continue` → blocked as "an inline
  environment-assignment prefix on 'git' … can redirect egress, swap
  identity, or inject a pager".
- `git -c core.editor=true rebase --continue` → blocked as "a
  `git -c <key>=<value>` … global option can execute arbitrary
  commands".

The gate is not specific to `core.editor`; it refuses the *forms*, so
no editor-related key gets through either one.

**The workaround's own side effect, and its fix.** `git commit
--no-edit` on a conflicted step reuses `.git/MERGE_MSG`, and for a
conflicted commit that file carries a trailing

```text
# Conflicts:
#   <path>
```

block (the second line is tab-indented in the real file). Merge-shaped commits default to `cleanup=whitespace`, which
keeps `#` lines, so every commit you resolved ships that block in its
message — permanently, and invisibly unless you go looking (`git log
--oneline` shows only the subject). After the rebase reports success,
check with `git log <base>..HEAD --format='%B' | grep -c 'Conflicts:'`
and, if non-zero, strip them in one pass:

```bash
git rebase -f <base> --exec "git commit --amend --no-edit --cleanup=strip"
```

`-f` forces the replay even though the branch is already on `<base>`,
and `--cleanup=strip` re-cleans each reused message, dropping the
comment lines. Verified on a 19-commit rebase with 7 resolved
conflicts: all blocks gone, `References:` trailers and multi-paragraph
bodies intact, and `git diff <old-head> <new-head>` empty — the tree is
byte-identical, only the messages changed. Do this *before* pushing, so
the force-push is a single event.

**How to apply:** any time a rebase, cherry-pick, or revert stops on a
conflict. Resolve the files with Edit (against the **worktree-absolute**
path — see [[worktree-path-not-main-clone]]), `git add <file>`,
`git commit --no-edit`, `git rebase --continue`. Sibling gate facts:
[[git-command-form-gate-cd-then-bare-git]] (no `cd X && git`, no
`git -C X`), [[commit-heredoc-gate]] (use `commit -F <file>` for
multi-line messages), [[worktree-isolation-gate-blocks-compound-bash]].
