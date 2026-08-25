---
name: agent-memory-inbox-capture
description: "Copy the invoking agent's own .claude/agent-memory/<plugin>-<agent>/ entry files that outlive this run into the session's per-branch agent-memory inbox under the scratchpad, so a curator can transfer the durable ones into CLAUDE.md or docs. Takes no arguments and commits nothing."
user-invocable: false
---

You are running the `/cc-tools:agent-memory-inbox-capture` skill. Move
the calling agent's own memory entries that outlive this run out of its
throwaway worktree and into the session's inbox, where the curator can
reach them.

You are the only stage that still has the run in context — what the
task was, what was tried, which observations were about this branch and
which about the repo. Every later stage reads an entry file stripped of
all of it, and resolves the resulting ambiguity by publishing, which is
how something that was true inside one worktree for an hour reaches
`CLAUDE.md`. So the session-scope filter in step 3 is yours and nobody
else's.

Do not rewrite an entry, and do not touch any other agent's
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
   `MEMORY.md`, report that nothing was captured and stop. That is a
   valid outcome: it means the run learned nothing worth recording.

3. **Ask of each entry whether it survives the run.** Would this mean
   anything to a reader who was not here — someone with the repo in
   front of them and no knowledge of this task, this branch, or this
   worktree? Answer it from the run itself, which is the context only
   you have; you are not grading whether the entry is worth publishing,
   which is the curator's call on the entries that reach it.

   An entry that fails is **dropped**, which means not copying it and
   nothing more. Nothing is deleted: the agent's own files stay where
   they are and die with the worktree.

4. **Copy each surviving entry file** into the same-named
   `<plugin>-<agent>/` subdirectory of this branch's inbox, creating
   the directories as needed. Copy the file's bytes unchanged, under
   its own name.

   - **`MEMORY.md` is skipped.** It is an index for a tree nothing
     reads back, and the inbox keeps no index of its own.
   - **A same-named file in the inbox is overwritten.** Two runs of the
     same agent on one branch — a first and a second `issue-fixer`
     round — write the same subdirectory, and the later run saw more.

5. **Commit nothing.** This skill never runs `git add`, `git commit`,
   or `git push`, and it never writes inside the repository.

## Output

One block:

```text
## Agent memory captured

Inbox:   <inbox path for this branch>
Entries: <N>
  - <plugin>-<agent>/<file>

Dropped (session-scoped) (<N>):
  - <plugin>-<agent>/<file> — <what about it was local to this run>
```

Name every drop: it is the one record anyone gets of an entry no later
stage will ever see. Report that nothing was captured when no entry
survived, or when there was none to begin with.
