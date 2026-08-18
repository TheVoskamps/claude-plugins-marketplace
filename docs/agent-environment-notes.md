# Agent environment notes

What an agent working in this repo runs into from the harness and its
gates, and the command forms that satisfy them. Every entry here is a
constraint on *how you invoke something*, not on what the code does.

This file does not describe gate verdicts as policy — the
permission-gate's classifier behavior is owned by
[`plugins/guardrails/hooks/permission-gate/README.md`](../plugins/guardrails/hooks/permission-gate/README.md),
and how to *establish* a fact about this repo's code is owned by the
`/docs` playbooks. What lives here is the agent-facing consequence: a
refusal you will hit, and the spelling that gets the work done instead.

## Know which refuser is talking

Several independent mechanisms refuse commands in this environment, and
each announces itself differently. Mistaking one for another sends you
hunting a workaround for the wrong gate:

- **The guardrails permission gate** names its own rule and offers a
  remediation ("resolves outside the current repository", "cannot be
  statically classified"). It also refuses some shapes by *form*:
  "Forbidden form `cd <path> && git ...`". Read that one's wording
  carefully — the message names the harness's CVE-2025-59536 gate as
  the reason the form is forbidden, but the refusal is the guardrails
  gate's own, and the string lives in
  `plugins/guardrails/hooks/permission-gate/forbidden_forms.go`.
- **The worktree-isolation check**, which opens "This agent is
  isolated in the worktree `<path>`" and closes with "a
  worktree-isolated agent's git operations must target its own
  worktree". Its middle clause names the shape it could not verify —
  "this command sets HOME", "this command is too complex to verify
  that it stays inside the worktree". No string of it appears anywhere
  in this repo, so it is not the guardrails gate talking, and no
  argument about the command's safety changes the verdict; split the
  command up or drop the redirection instead.
- **Claude Code's auto-mode classifier** says only "Blocked by
  classifier" with no reason. Why it fired is a guess; treat the
  outcome as the only measured thing.

## Git command forms

- A multi-line commit message goes in a file:
  `git commit -F <path>`, with the file written under
  `.claude/tmp/<task-slug>/`. The heredoc-into-substitution form
  `git commit -m "$(cat <<'EOF' … EOF)"` is refused, because a git
  argv carrying a command substitution is not all static literals.
- The one substitution a git argv accepts is an anchor:
  `$(git rev-parse --show-toplevel)`, `$(git rev-parse
  --git-common-dir)` and `$(pwd)` resolve in every word position. A
  relative literal path is simpler and always works; reach for the
  anchor only when the path must be absolute.
- `cd <path> && git …`, `git -C <path> …` and
  `git --git-dir=<path>/.git --work-tree=<path> …` are all refused, so
  there is no way to run git against another worktree. Only the first
  two are named forbidden forms by the guardrails gate, and its `-C`
  arm fires on an **absolute** path only — a relative `-C` falls
  through to the ordinary classifiers, and a git operation aimed
  outside your own worktree still does not survive the
  worktree-isolation check. Within your own worktree, a bare
  `cd <path>` in one Bash call followed by a bare `git <subcommand>`
  in a separate call is the accepted pattern.
- A git command whose arguments name a path with a `git`-prefixed
  component (`plugins/git-tools`) can be refused for naming git more
  than once. A deeper path component, or the parent directory, passes.
- `git reset --hard` is refused in a subagent; the refusal names its
  replacement, `git checkout --detach origin/<branch>`.
- Both ways of suppressing git's editor are refused —
  `GIT_EDITOR=true git …` as an inline environment prefix, and
  `git -c core.editor=… …` as a global option that could execute
  arbitrary commands. The inline prefix is refused by its *form*,
  whatever the variable; the `-c` global is refused by its *key*,
  against a list of code-executing knobs that carries every editor key
  git honors — `core.editor` and `sequence.editor` alike — so there is
  no editor spelling to find here.

### Finishing a conflicted rebase without an editor

Stage the resolution, run a bare `git commit --no-edit`, then a bare
`git rebase --continue`.

That workaround has a side effect worth undoing. `git commit
--no-edit` on a conflicted step reuses `.git/MERGE_MSG`, which carries
a trailing `# Conflicts:` block, and a merge-shaped commit defaults to
`cleanup=whitespace`, which keeps `#` lines. Every commit you resolved
then ships that block permanently and invisibly — `git log --oneline`
shows only the subject. Check the **whole** range, since an earlier
round that skipped the strip left its own blocks and a commit that
conflicts twice accumulates two:

```bash
git log origin/main..HEAD --format='%B' | grep -c 'Conflicts:'
```

If that is non-zero, strip them in one replay driven by a script file:

```bash
git rebase -f <base> --exec .claude/tmp/<slug>/strip-msg.sh
```

where the script is `exec git commit --amend --no-edit
--cleanup=strip`. The inline spelling —
`--exec "git commit --amend --no-edit --cleanup=strip"` — is refused
by the auto-mode classifier. Do this before pushing, so the force-push
is a single event.

## Paths

- Build every `Read`, `Write` and `Edit` path from the worktree root
  the harness prints in its environment block, never from the primary
  clone's path. `Write` and `Edit` refuse a primary-clone path
  outright; `Read` does not — it silently returns the *other*
  checkout's bytes, so a claim you "verified" is verified against the
  wrong branch. The tell is a line-number disagreement between a
  `grep -n` run through Bash (which uses the worktree cwd) and a
  `Read` window.
- The read-before-write requirement is tracked per exact path string,
  so having read the primary clone's copy does not satisfy it for the
  worktree copy.
- `mkdir -p` a new scratch directory before writing into it. A write to
  a correct worktree path whose parent does not exist yet is refused
  with the same "edit the worktree copy" message, which sends you
  hunting a path bug that is not there.
- cwd does not persist between Bash calls in a subagent.
- Every path-shaped argument is graded, not only an explicit target. A
  `cp` whose *source* is out of repo is refused even though the write
  lands in-repo; so is a `find` rooted outside, and so is an awk range
  pattern containing `/`, which reads as a second file argument. An
  **empty string** operand is graded as a path and is not contained,
  which is why BSD `sed -i ''` has no working spelling on macOS — use
  `Edit`, or a small `python3` helper under `.claude/tmp/<slug>/` for
  mechanical line surgery.
- A path is graded after symlink resolution, and the refusal names the
  resolved target. A user-global config that links into another
  checkout — `~/.config/<tool>/config.toml` under a dotfiles repo — is
  refused as a cross-repo read, so establish such a value through the
  tool that owns it (`mise current node`, `git config --get`) instead
  of reading its file.
- Redirect scratch *before* it is created rather than reading it
  afterward: set `TMPDIR=<repo>/.claude/tmp/<slug>` on the command that
  creates the temp dir, so every downstream `mktemp` lands in bounds.
- Bind-mounting an out-of-repo path into a container is **not**
  refused, so a host file you cannot `grep` you can still read from
  inside a container.
- The harness scratchpad under `/tmp/claude-<uid>/` is carved out and
  reads fine.
- `HOME=<dir> <cmd>` is refused by the worktree-isolation check, whose
  message is about git: a redirected HOME injects git configuration
  whose effect on where git writes cannot be verified. The command
  need not be git — a bare `pwd` under a HOME prefix is refused too.
  Run HOME-redirected experiments inside a container, where the
  redirection is the container's business.
- A compound one-liner — an `&&` chain, a `for` loop, a `$VAR` path, a
  `"$PWD"` argument — is refused as unverifiable even when it stays in
  bounds. Write it to a script under `.claude/tmp/<slug>/` and run
  `bash <script>`, or issue one bare command per call.

## Tooling

- The Bash tool's shell is **zsh**. Sourcing a bash library into it and
  calling its functions produces misleading symptoms — exit 127 and
  empty output from a function whose commands resolve fine in the same
  shell. Drive bash code with `bash -c '. <lib>; <fn> <args>'`, or just
  run the real test file with `bash <file>`.
- `rm` and `cp` are aliased interactive here; use `rm -f` and
  `/bin/cp -f`.
- Node is managed by **mise**, and the version comes from the
  user-global `~/.config/mise/config.toml`, which applies in every
  directory. A worktree carries no version-pin file of its own and
  needs none, so a bare invocation resolves:

  ```bash
  npx markdownlint-cli2 <file>…
  ```

  Do not write a pin file into the worktree to "fix" a version
  problem, and do not run `mise use`, which writes one. At the repo
  root every spelling of one is gitignored — `.tool-versions` by its
  own rule, `mise.toml` and `.mise.toml` by the top-level `/*` — so a
  stray pin sits there invisibly and outlives the run rather than
  showing up in a diff for you to notice. Written into a whitelisted
  subtree (`docs/`, `plugins/`) it does land in the diff, which is the
  other half of the same problem. When a specific version genuinely
  has to be named, pass it per-command instead —
  `mise exec node@<version> -- npx …`, with the version read from
  `mise current node`.
- A bare `curl` to `github.com`, `raw.githubusercontent.com` or
  `api.github.com` returns nothing from a Bash call — there is no
  direct network egress. `gh api` and `WebFetch` both work, because
  they travel the harness's own network path.
- Reads under `~/go/pkg/mod` are refused. `go doc
  <import-path>.<Symbol>` queries the same already-downloaded module
  through the `go` tool and is not.

## GitHub CLI

- `gh pr diff` can silently drop whole text files from a PR that also
  carries committed binaries, with no truncation warning, and `-e` does
  not filter the binary sections out. Cross-check against local git
  objects with `git diff <merge-base> HEAD --stat`.
- `gh pr create` and `gh pr list` are GraphQL and can 503 persistently
  while REST answers every time. Settle what happened over REST rather
  than with `gh pr list`:

  ```bash
  gh api "repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=all" --jq length
  ```

  then create over REST, where `-F draft=true` sends a real boolean and
  `-F body=@<file>` avoids the multi-line-argument problem entirely.
- Never invoke a publishing verb to establish behavior, in any
  spelling — see the root `CLAUDE.md` for the rule and for the safe way
  to answer each question that tempts you into one.

## Branch and worktree state

- Another worktree can hold the branch, so `git checkout <branch>`
  fails naming its path. There is no way to inspect that worktree's git
  state from inside a subagent, so do not go looking for one. Work
  detached instead: `git checkout --detach origin/<branch>`, commit,
  and push with an explicit refspec `git push origin
  HEAD:refs/heads/<branch>`. You were never on a branch, so the
  end-of-run `git branch -D` is a no-op.
- Never remove another worktree to reclaim a branch, and never
  `--force` a removal. A plain `git worktree remove` *is* the
  dirtiness check: git refuses one holding uncommitted or untracked
  files, and a refusal is the signal to stop rather than destroy work
  somebody put there.
- A worktree that `git worktree list` shows as `(detached HEAD)` at the
  branch's tip is not a claim on the branch, and checking the branch
  out elsewhere succeeds.
- PR branches here get force-rebased onto main by this repo's own
  automation, mid-session. Treat a "diverged" status or a rejected
  plain push as expected background noise: save the delta
  (`git diff` or `git format-patch -1 --stdout`) to a scratch file,
  `git checkout --detach origin/<branch>`, recreate the local ref from
  the current remote tip, re-apply, verify the delta is unchanged, and
  push. Never force-push out of it, and re-fetch immediately before
  every push rather than trusting a fetch from an hour earlier.
- Where a new branch is rooted is settled by **reading the ref**, never
  by the fetch's exit status, and it fails in both directions. A
  `git fetch origin main` that reports no error can leave
  `origin/main` lagging in a freshly created worktree, so
  `git switch -c <name> origin/main` roots the branch behind the real
  tip; compare `git rev-parse origin/main` against `git log -1 HEAD`
  straight after creating it, and repair with
  `git branch -f <name> origin/main` (from a detached HEAD, since git
  refuses to force-update the branch this worktree has checked out)
  followed by `git checkout origin/main -- .`, because neither
  `branch -f` nor `reset --soft` touches tracked file contents. In the
  other direction, a fetch that never ran — an SSH timeout at
  branch-create — usually blocks nothing: a subagent worktree shares
  the primary clone's object store and refs, so `origin/main` already
  carries whatever the orchestrator last left there. Read it, and
  proceed when it matches. The end-of-run push still needs the
  credential, so a genuinely missing one surfaces there instead.
- `git status` compares against the branch's own remote ref and says
  nothing about main. `git merge-base --is-ancestor origin/main HEAD`
  is the check that answers whether a branch is behind. A PR reading
  `CONFLICTING` never self-heals — the scheduled rebase sweep acts on
  `BEHIND` and `BLOCKED` and deliberately drops `DIRTY`.
- After rebasing onto main, re-read each touched plugin's `version`
  against main's. When both sides bumped the same plugin to the *same*
  value, git resolves it silently and the file drops out of the diff
  entirely, leaving the per-PR bump rule unsatisfied with no conflict
  to tell you. The check that catches it is the file's **absence** from
  `git diff --stat origin/main HEAD`, not the plausible-looking value
  in `plugin.json`.
