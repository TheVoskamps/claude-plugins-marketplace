# Agent tooling notes

**Who reads this and when:** any agent whose command here succeeded but
whose result surprised it, or who is about to assert what a tool did.
Read it before forming a hypothesis about the tool.

How the tools an agent reaches for in this repo actually behave, where
that differs from the obvious expectation. These are not verification
techniques — `docs/verification-playbook.md` and its two siblings own
those — and not permission-gate policy, which
`plugins/guardrails/hooks/permission-gate/README.md` owns. This file is
for the cases where a command runs, returns success, and means
something other than what it appears to.

## The Bash tool's shell is zsh, so drive bash scripts under bash

Sourcing a bash library into the tool's shell and calling one of its
functions produces misleading symptoms: a function that shells out can
return exit 127 with empty output while `command -v` for that same
program succeeds in the same shell, and `set -x` shows the body
executing and silently producing nothing. The function is fine; the
zsh-versus-bash sourcing is the artifact.

Run `bash -c '. <lib>; <func> <args>'` or `bash <script>` instead.
Better still, run the committed test file, which is already a `bash`
invocation — hand-rolling a source-and-call reproduces the trap.

## `awk` rejects the `--` end-of-options separator

`awk 'prog' -- "$file"` fails with `awk: can't open file --`. The BSD
awk on macOS reads `--` as a filename, where `head`, `cat` and `mv`
take it as the end-of-options marker. A script hardened against
leading-dash paths by writing `-- "$file"` uniformly therefore turns a
working read into a hard error, and only the arm that reaches the `awk`
call shows it.

Keep `--` on the utilities that document it, drop it on `awk`, and run
the arm rather than assuming the guard is inert.

## A newline test written with command substitution matches every string

`case "$x" in *"$(printf '\n')"*)` matches **every** value: command
substitution strips trailing newlines, so the pattern collapses to
`**`. Hold the newline in a variable instead:

```bash
newline='
'
case "$x" in *"$newline"*) ... ;; esac
```

The broken form reads as obviously correct and fails open, so exercise
a matching and a non-matching input before believing either spelling.

## A successful fetch can leave the remote-tracking ref behind

`git fetch origin <branch>` updates `FETCH_HEAD`, but in a freshly
created worktree the local `origin/<branch>` ref can still lag. A
branch created from it then roots several commits behind the real tip
with no error anywhere — the fetch reported success, and the ref it was
supposed to advance did not move.

So read the ref rather than trusting the fetch: compare
`git rev-parse origin/<branch>` against what you expect before, or
immediately after, creating the branch. If the new branch's `HEAD` does
not match the ref right after creation, it was rooted wrong. Repair
with `git branch -f <name> origin/<branch>` — which requires switching
off the branch first, since git refuses to force-update the branch
checked out in the current worktree — followed by a checkout of the
ref's contents, because a reset alone does not touch tracked-file
contents. Re-apply any uncommitted edits afterwards.

## An argv is not what caps a long body — quoting is

`getconf ARG_MAX` is 1048576 here, and a single 80 KB argument reaches
an `execve`d program intact. So "the body is too large for a
command-line argument" is the wrong diagnosis for a body of tens of
kilobytes, and reaching for a file on that reasoning gets the right
answer for a reason that will not survive a reader who checks it.

What actually breaks an inline body is the shell. A body spelled into
a double-quoted word — `gh pr review <PR> --approve --body "<body>"` —
has every backtick and `$` in it read by the shell before `gh` sees a
byte, and a review or PR body is Markdown that quotes code throughout.
A 26 KB review body posted on this repo carried backticks on 97 of its
lines.

So pass a long body by path. `gh`'s body-carrying verbs each take
`-F`/`--body-file` alongside `-b`/`--body` and reject both at once, so
the file form needs no quoting at all: stage the text with `Write`
under `<repo-root>/.claude/tmp/<task-slug>/` and name the path.
`sdlc:theorem-based-pr-reviewer` posts every review that way, through
`/github-prs:pr-review-submit --body-file`.

## `gh pr create` is GraphQL and can fail while REST is healthy

`gh pr create` uses GraphQL for both its already-exists pre-check and
the create mutation, and it can return `HTTP 503: No server is
currently available` on consecutive attempts while `gh api repos/...`
answers every time. That is not an authentication problem, not a
whole-API outage, and not something another `gh` flag repairs.

Establish what happened before retrying, because the two failure
spellings mean different things: a failure in the pre-check created
nothing, while a failure in the create itself is ambiguous. Do not
settle it with `gh pr list`, which is GraphQL too. Ask REST:

```bash
gh api "repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=all" --jq length
```

Then create over REST, which is the same sanctioned operation in a
different spelling. `-F draft=true` sends a real JSON boolean where
`-f` would send the string, and `-F body=@<file>` reads the body from a
file, which sidesteps the multi-line-argument problem entirely — the
same reason a commit message goes through `git commit -F <file>` here.
Verify draft-ness and the closing line by re-reading the created PR
rather than trusting the create's own output.

## `gh pr review` is GraphQL too, and its refusals are the server's words

`gh pr review` does not use the REST reviews endpoint either:
`api.AddReview` in `api/queries_pr_review.go` builds an
`AddPullRequestReviewInput` and calls `client.Mutate`, so every failure
arrives as an error on the `addPullRequestReview` mutation rather than
as a bare REST API message. Read that path in `cli/cli` at the tag
`gh --version` reports —
`gh api "repos/cli/cli/contents/<path>?ref=<tag>" --jq .content` piped
through `base64 -d`.

That read settles the route and never the message text, because the
client sends the mutation and the wording comes back from GitHub. The
self-review refusals `/github-prs:pr-review-submit` quotes verbatim are
that wording, and they are real: a self-directed `request_changes`
surfaces in full as `failed to create review: GraphQL: Review Can not
request changes on your own pull request (addPullRequestReview)`,
observed on a real round here, and its `approve` sibling is the same
refusal on the other event, worded `Can not approve your own pull
request` — that core wording only, since no round here has surfaced
the whole line it arrives in. Match a refusal on the core wording
rather than on the whole line or on a status code: `gh` wraps it in
the prefix and the mutation-name suffix above, which the `approve`
line is unmeasured on, and the route above puts the failure in the
mutation's errors, not in a transport status, so no status code is
established here at all. Posting a review is ordinary work in this
repo rather than a probe of the verb, so a refusal a real round hits
is where such a string is established — do not label one
unsourceable.

## `yq` traps in the mikefarah build

**`unique` does not sort.** It removes duplicates while preserving
first-seen order, so two lists holding the same set in different orders
canonicalize differently and hash differently. Any canonical form meant
to be order-insensitive needs `unique | sort` for scalars, or
`sort_by(<key>)` for object lists. Pin it with a test that feeds the
same set in two orders and asserts equal output.

**A bare comma expression inside a `.[]` pipe can drop a branch.**
Writing `.[] | (a), (b)` silently swallows an earlier element's `b`
output when a later element's `b` is empty — not the missing line, and
not an empty placeholder, but a value from a different element
vanishing entirely. Wrap the branches and flatten instead:
`.[] | [(a), (b)] | .[]`, which emits one array per element so an empty
branch still contributes its placeholder. A uniform, fully-populated
fixture does not surface this, so any test for it needs an element
whose branch is deliberately empty.

This is an empirical trap rather than documented behavior; it has not
been traced to a root cause in the yq source, so treat the workaround
as the rule and do not reason from a model of why it happens.

## `gh pr diff` can silently drop files from a PR with binaries

When a PR includes a committed binary, that content renders as a
`GIT binary patch` block that is not flagged as "Binary files differ",
and `gh pr diff --patch` can return a diff that omits several of the
PR's changed **text** files with no truncation warning at all. The
`--exclude` flag does not reliably filter the binary sections out
either.

So do not trust `gh pr diff` alone on a PR that touches compiled
artifacts. Cross-check against local git objects with
`git diff <merge-base> HEAD --stat`, which is unaffected.

## Read the worktree, never the primary clone's path

Build every absolute path from the worktree root — the cwd the harness
gives you, or `git rev-parse --show-toplevel` — and never from the
repository path that appears throughout injected context. That path is
the *primary clone*, which sits on the default branch.

From a linked worktree the permission-gate denies such a read: a `Read`
of a primary-clone working file, and a `cat` / `grep` / `head` naming
one, each come back as a worktree-escape deny. So the failure is loud,
and the message carries the fix — but read which of its two fixes it
gave you. When this worktree holds a file at the corresponding path,
the message prescribes that path and you re-read there. When it does
not — reaching into another agent's worktree under the primary clone's
`.claude/worktrees/` is how that happens, since this worktree never
checks that tree out — the message says so and prescribes
`git show HEAD:<path>`, because the bytes are not on your disk at all.
Do not hand-build the substituted path yourself: for the second case it
names a file that does not exist.

The deny grades a statically-resolvable path handed to a tool or
command it knows, so these cases reach the wrong bytes without it
firing:

- **A tool the hook never runs on.**
  `plugins/guardrails/hooks/hooks.json` matches
  `Bash|Read|Write|Edit|MultiEdit|NotebookEdit|mcp__.*`. A tool
  outside that list — `Grep` and `Glob` among them — raises no
  `PreToolUse` event for the gate, so whatever path it is pointed at
  earns no verdict at all, not even a defer.
- **The wrong ref.** `git show main:<path>` or
  `git show origin/<base>:<path>` extracts bytes from a commit, so no
  containment rule grades it. Evidence comes from `HEAD`, which is
  per-worktree: after a detached checkout it names the commit you
  checked out, not the branch the primary clone sits on. `git show
  HEAD:<path>` is also the remedy when you want bytes off a ref rather
  than off disk.
- **A path the gate cannot resolve statically.** A read behind a
  dynamic path defers rather than denying, so the containment check
  never runs on it.
- **A program the gate has no read table for.** Containment runs on
  the `Read` tool and on the curated read commands (`cat`, `grep`,
  `head`, `sed`, `awk`, `jq`, `find`, the pagers). A `python3 -c`, a
  `node -e`, or any other unrecognized program reaches the residual
  defer, so the primary-clone path it opens is never graded.
- **`git`'s own read subcommands.** `git` is a recognized program, but
  the gate classifies it by *subcommand shape* — the identity write,
  the push refspec, the remote re-aim, the subagent `reset --hard` —
  and reads no path operand for containment. Every other subcommand
  allows, so `git diff --no-index <primary-clone>/<path> <path>` reads
  the wrong tree from a statically-resolvable path with no deny.

The tell for a wrong-tree read is a line-number mismatch between
`grep -n`, which runs from the cwd, and a Read window: if the grep says
a phrase is on one line and your Read of that range shows something
else, you are reading two different files.

The injected `CLAUDE.md` in system context is a stale copy of the
primary clone's and can run whole sections behind the worktree's. Read
the worktree's copy before deciding what a repo rule says.

## A branch already claimed by another worktree

`git checkout <branch>` can fail naming another worktree that holds
the branch — commonly a live worktree someone is using to test the
branch by hand. Do not delete, prune, or force it. Work detached
instead:

```bash
git checkout --detach origin/<branch>
# edit, commit
git push origin HEAD:<branch>
```

No local branch is created, so there is no end-of-run branch to
release, and the other worktree's local ref is simply behind origin
afterwards — say so rather than repairing it.

## Remove a worktree by the path `git worktree list` prints

`git worktree remove` resolves a short argument two ways, in order,
and both make a short argument a worse instruction than it looks.
Measured on git 2.55.0 against a repo holding a worktree at
`<repo>/.claude/worktrees/probe-align` and a second one nested at
`<repo>/.claude/worktrees/probe-align/.claude/worktrees/probe-align`:

1. **Cwd-relative first.** From the outer worktree's own root,
   `git worktree remove .claude/worktrees/probe-align` removed the
   **nested** worktree and exited 0. The argument named a registered
   worktree relative to the cwd, so that one won outright — no
   ambiguity was reported, and the worktree the caller meant was left
   in place.
2. **Component-aligned suffix second, and it must be unique.** From
   `<repo>/.claude`, where the argument is no relative path at all,
   the same string removed the one remaining worktree once the nested
   one was gone. A bare `<name>` works the same way. A suffix that
   starts mid-component matches nothing — `obe-align` finds no
   worktree whose path ends `/probe-align`.

So a short argument is wrong two different ways: it can hit a
**different** worktree than you meant because of where you stand, and
it can hit none because it is **ambiguous**. Both resolutions depend on
state the caller does not control — the cwd, and what else is
registered at the moment — so the absolute path the listing prints is
the only argument that names one worktree unconditionally. When the
suffix matches more than one, git answers

```text
fatal: '<arg>' is not a working tree
```

which is also exactly what it answers when nothing matches. The error
names the path but not the reason, so an ambiguous argument reads as
"the worktree is already gone".

The absolute path `git worktree list` prints is unique by
construction and names the same worktree from any cwd, so it settles
on the first arm and never reaches the second. That is the whole
reason to take the path from the listing rather than composing one:

```bash
git worktree list
git worktree remove <absolute-path-from-the-listing>
```

## A subagent's worktree is a sibling, not a nested worktree

An `isolation: worktree` subagent spawned from **inside** another
worktree does not get its worktree nested under the spawner's. Measured
2026-08-20: a `general-purpose` agent running in
`.claude/worktrees/agent-a7c796714c0aba1b9` spawned a worktree
subagent, which landed at `.claude/worktrees/agent-a53d463b5c46a2a27` —
a sibling under the **primary clone**, sharing the same
`--git-common-dir`. The spawner's own worktree contained no
`.claude/worktrees/` directory at all.

Re-confirmed 2026-09-01 from inside a spawned agent's worktree:

```console
$ pwd
<repo>/.claude/worktrees/agent-a98761e946f4e4e74
$ git rev-parse --git-common-dir
<repo>/.git
$ ls -a .claude/
.  ..  agent-memory
```

So the topology under `.claude/worktrees/` is flat: one directory per
live agent, all siblings, all registered to the primary clone. A rule
justified by "the spawner's worktree carries a `.claude/worktrees/` of
its own" is justified by something that does not happen — the
absolute-path rule above stands on the two resolution behaviours it
measures instead, which need no nesting to bite.

## A worktree lock's PID is the session's, not the agent's

The harness locks each `isolation: worktree` worktree with a reason of
the shape

```text
claude agent agent-<hash> (pid NNNN start <date>)
```

and `NNNN` is the PID of the `claude` **session process** that spawned
the agent, not of the agent. Measured 2026-09-01 in this repo: seven
worktrees under `.claude/worktrees/`, each holding a different agent,
all read back the same `pid 67009` with the same `start` stamp, and
PID 67009 is a live `claude` process belonging to a session other than
the one reading the locks.

Two consequences for anything gating on that PID. It carries a `start
<date>` field, so an exact or end-anchored match against
`... (pid NNNN)` never fires. And a live PID means a session is
running, never that a particular agent still is — the PID outlives
every agent that session spawns, so a gate that reads liveness as
"an agent may be mid-run" makes a session unable to reclaim any
worktree it ever spawned.

A session tells its own locks from a foreign session's by process
ancestry. The Bash tool's shell is a direct child of the session
process, so walking up from `$$` reaches the PID stamped in the lock:

```console
$ pid=$$; while [ "$pid" -gt 1 ]; do ps -o pid=,command= -p "$pid"; \
    pid=$(ps -o ppid= -p "$pid" | tr -d ' '); done
80879 /opt/homebrew/bin/zsh -c source .../shell-snapshots/snapshot...
 9376 claude --name One cleanup pass #134 claude-plugins-marketplace...
 9100 -zsh
```

That holds from inside a spawned agent's own worktree, which is where
the listing above was taken.

## A push over SSH can hang in the foreground and succeed in the background

`git push` over SSH to `github.com` intermittently stalls here. The same
command can fail with `ssh: connect to host github.com port 22:
Operation timed out`, then produce no output at all until the Bash
tool's foreground timeout kills it, and then complete with exit 0 under
`run_in_background`. Reachability is not the variable that moved:
`nc -vz github.com 22` reports `succeeded` while a push is hanging.

The stall reads as an authentication or credential failure and is not
one. Believing that leads to reporting a blocked push, or to rewriting
the remote URL or reaching into the credential agent — both forbidden
on an agent's own initiative.

So re-run the identical command with `run_in_background: true` and read
the task output before concluding anything about credentials. Settle
the outcome against the remote with `git ls-remote origin <branch>`
rather than against the command's exit path. Escalate per
`rules/credential-surfaces.md` only once an actual authentication error
text comes back.
