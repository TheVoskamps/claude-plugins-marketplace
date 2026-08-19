# Agent tooling notes

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

## Two `yq` traps in the mikefarah build

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
the *primary clone*, which sits on the default branch. A Read against
it succeeds and returns real, plausible, pre-branch prose, so a claim
you believe you verified is verified against the wrong branch, with no
error and no warning.

The tell is a line-number mismatch between `grep -n`, which runs from
the cwd, and a Read window: if the grep says a phrase is on one line
and your Read of that range shows something else, you are reading two
different files.

The other remedy is to bypass the filesystem entirely and extract the
bytes from the ref you mean: `git show HEAD:<path>` — or
`git show origin/<branch>:<path>` — reads the path out of that commit
rather than off disk, so it cannot reach another checkout's working
files, whatever path the context handed you. Worktrees share one ref
store, so the anchor that makes this yours is `HEAD`, which is
per-worktree: after a detached checkout it names the commit you
checked out, not the branch the primary clone sits on.

The injected `CLAUDE.md` in system context is that same stale copy and
can run whole sections behind the worktree's. Read the worktree's copy
before deciding what a repo rule says.

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
