---
name: agent-memory-inbox-capture
description: "Copy the invoking agent's own .claude/agent-memory/<plugin>-<agent>/ entry files into the session's per-branch agent-memory inbox under the scratchpad, so a curator can transfer the durable ones into CLAUDE.md or docs. Takes no arguments, commits nothing, and curates nothing."
user-invocable: false
---

You are running the `/cc-tools:agent-memory-inbox-capture` skill. Move
the calling agent's own memory entries out of its throwaway worktree
and into the session's inbox, where the curator can reach them.

This is the agent's own memory moving, not curation. Do not grade an
entry, do not rewrite one, and do not touch any other agent's
subdirectory.

Read `skills/lib/agent-memory-inbox.md` for the inbox path, its
`<plugin>-<agent>/` layout, and how the branch and the scratchpad are
resolved. That contract is the only statement of the path; this skill
does not restate it.

## Invocation

```text
/cc-tools:agent-memory-inbox-capture
```

No arguments. Everything the skill needs — the calling agent's memory
directory, the current branch, and the session scratchpad — comes from
the invoking agent's own context and working tree.

## Execution

1. **Resolve the branch**, before any end-of-run detach:

   ```bash
   git branch --show-current
   ```

   An empty result means HEAD is detached and the branch is
   unrecoverable. Report that and stop; capture nothing rather than
   writing to a wrongly-named inbox.

2. **Find the entries.** The calling agent's own memory directory is
   `.claude/agent-memory/<plugin>-<agent>/` relative to its cwd, where
   `<plugin>-<agent>` is its own name — `sdlc-issue-developer`, say.
   Take that name from your own identity, never by looking at what the
   tree happens to hold, and sweep that one directory:

   ```bash
   find .claude/agent-memory/<plugin>-<agent> -type f -name '*.md'
   ```

   A sibling directory belongs to another agent and is never read. In
   a repo that gitignores `.claude/agent-memory/` a fresh worktree has
   none; in a repo that commits the tree the worktree carries every
   agent's committed entries, and copying those would file another
   run's lessons under this run's capture.

   If the directory is absent, or holds no file other than a
   `MEMORY.md`, report "nothing to capture" and stop. That is a valid
   outcome: it means the run learned nothing worth recording.

3. **Copy each entry file** into the same-named `<plugin>-<agent>/`
   subdirectory of this branch's inbox, creating the directories as
   needed. Copy the file's bytes unchanged, under its own name.

   - **`MEMORY.md` is skipped.** It is an index for a tree nothing
     reads back, and the inbox keeps no index of its own.
   - **A same-named file in the inbox is overwritten.** Two runs of the
     same agent on one branch — a first and a second `issue-fixer`
     round — write the same subdirectory, and the later run saw more.

4. **Commit nothing.** This skill never runs `git add`, `git commit`,
   or `git push`, and it never writes inside the repository. The
   entries stay in the agent's worktree as well as the inbox; the
   worktree's copy dies with the worktree.

## Output

One block:

```text
## Agent memory captured

Inbox:   <inbox path for this branch>
Entries: <N>
  - <plugin>-<agent>/<file>
```

Or the single line `nothing to capture` when step 2 found no entry
file.
