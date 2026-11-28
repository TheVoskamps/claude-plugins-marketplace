---
name: memory-grade
description: "Grade the memories memory-tools captured for a checkout's repo, read-only. Reads every record under the repo's memory-tools state directory, takes each memory's latest record, and reports one grade per memory: delete with its evidence, durable, or no code home, each surviving one with the destination it would land in and the constraint as it would be written there. Writes, deletes and commits nothing. Takes an optional checkout path, the current directory by default."
argument-hint: "[<checkout-path>]"
---

# Memory Grade

You are running the `/memory-tools:memory-grade` skill. Grade what the
capture hook recorded for one repo, and report it. You change nothing:
no file is written, deleted, moved or committed, in the checkout or in
the state directory, and a grade is never applied.

Read `skills/lib/memory-grading.md` for the rubric before you grade: the
delete cases and the evidence each needs, what counts as durable, what
has no code home, where a surviving memory would land, and how its
constraint is phrased. This skill restates none of it.

## Invocation

```text
/memory-tools:memory-grade [<checkout-path>]
```

- `<checkout-path>` (optional) — a local checkout of the repo whose
  memories are graded; the current directory when omitted. It is also
  the tree the rubric's reads are made in.

## Execution

### Find the repo's records

Read the checkout's `origin`:

```bash
git -C <checkout-path> remote get-url origin
```

With no `origin`, stop and say so: nothing is recorded for a repo
without one. Otherwise reduce the URL to `<host>/<owner>/<repo>` the way
the hook does — for `https://` and `ssh://` URLs the host is what
follows `://` up to the first `/`, and for the `user@host:path` form it
is what precedes the `:`; drop a `user@` and a `:port` from the host, a
trailing `/` and `.git` from the path, and take the path's last two
segments as owner and repo.

The records are the `*.yml` files directly in
`${XDG_STATE_HOME:-$HOME/.local/state}/memory-tools/<host>/<owner>/<repo>/`,
with `$XDG_STATE_HOME` used when set and non-empty. List them:

```bash
ls <that directory>
```

A directory that is absent or holds no `*.yml` file is not a failure:
report that there is nothing to grade and stop. A read the permission
system refuses is a failure: name the path and stop, rather than
reporting nothing to grade.

### Pick each memory's record

Read every record. Each is YAML with the keys `kind`, `source-path`,
`tool`, `session-id`, `branch`, `captured-at` and `content`, and
`content` is the memory file's whole text after that call.

A memory is one `source-path`. Of its records, grade only the one with
the latest `captured-at`, and the file name, which opens with the same
instant, breaks a tie: the later name wins. Count its records for the
report. Grade the record's `content`, not the file at `source-path`,
which may since have changed or gone with its worktree.

### Grade

Read what the rubric says to read in `<checkout-path>`, then give every
memory exactly one grade: **delete**, **durable** or **no code home**.

## Output

One line per memory, grouped by grade:

```text
## Memory grades — <host>/<owner>/<repo>

Delete (N):
  - <source-path> (<kind>, <n> records) — <the delete case>: <the check that substantiates it>

Durable (N):
  - <source-path> (<kind>, <n> records) -> <destination> — <the constraint as it would be written there>

No code home (N):
  - <source-path> (<kind>, <n> records) -> <destination> — <the constraint as it would be written there>
```

A `<destination>` that does not exist yet carries `(new)` after its
path. A memory graded durable or no code home because its delete could
not be substantiated, or because it cleared neither bar, says so after
its constraint.

Where there was nothing to grade, the report is that one fact and the
directory it looked in.
