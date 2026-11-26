# git-tools

`docs/rules/plugin-authoring-constraints.md` — read when adding,
  removing or changing a git-tools skill or executable. Kernel: the
  plugin's user-manual roster changes in the same PR.

`git-branch-create` encodes the issue set in the branch name and
`git-issues-from-branch` is its inverse, both through the one
`git-issue-branch` script, and `github-prs` and `sdlc` depend on that
encoding.

- Change the branch-name grammar, the issue-argument forms, `encode`'s
  validation errors or `decode`'s reconciliation outcomes in
  `bin/git-issue-branch`, whose header comment states them, together
  with `test/git-issue-branch-test.sh`, and restate them in no
  `SKILL.md`; the encode-decode round trip is the contract to re-check.
- Every script under `bin/` runs under the bash 3.2 macOS ships, and a
  command it does not handle that fails exits 1 with a line naming the
  command, never with the tool's own status.
- An exit status a script's header lists is a contract callers branch
  on, so each keeps the one condition it names: a new condition the
  script can detect for certain gets a code of its own, and a failure it
  cannot classify stays 1.
- `git-branch-sync push` decides against the tip `checkout` recorded;
  `rebase` and `continue` leave that record alone, and nothing else
  records whether a rebase ran. A change that lets `push` fetch before it
  decides, or lets a rebase touch the record, changes what the lease
  refuses, and the other-writer cases in `test/git-branch-sync-test.sh`
  re-check it.
- `reclaim` runs its unfinished-work check before its lock check, and
  `--holder-ended` reaches only the lock check: a flag that skipped the
  first would make `reclaim` discard work. Every read of a holder, and its
  detach, goes through `has_working_tree`, because git run in a path that
  is no longer the holder's worktree answers for whatever repository
  encloses it.
- `git-default-branch`'s non-zero exit is what a caller reads as "no
  protected branch is known", so a new source for the name goes in ahead
  of that failure, in the order the sources are trusted, rather than as a
  new exit status; a source read off the clone rather than the host goes
  after the GitHub setting, never before it.
