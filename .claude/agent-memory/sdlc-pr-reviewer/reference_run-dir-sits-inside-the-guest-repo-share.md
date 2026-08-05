---
name: run-dir-sits-inside-the-guest-repo-share
description: claude-vm's $RUN lives INSIDE the repo, and under repo.mount live the whole repo is the guest's rw share — so any new artifact a PR writes under $RUN is guest-readable and guest-writable. Check every new $RUN path against both repo modes.
metadata:
  type: reference
---

When a claude-vm PR adds a new host-side artifact, trace where it lands
before accepting the isolation story around it:

- `RUN="$REPO_SRC/.claude/tmp/$RUN_ID"` whenever the launcher is started
  from inside a git repo (`claude-vm.sh`, the `RUN_ID` block) — the run
  dir is *inside the operator's repo*, not in `$TMPDIR`.
- `repo.mount: clone` (the default) shares `$RUN/worktree`, so a sibling
  under `$RUN` is outside the share.
- `repo.mount: live` shares `$REPO_SRC` itself, and the image's fstab
  mounts tag `repo` **rw** (`provisioners/podman-mkosi.sh`). So in live
  mode *everything under `$RUN` is reachable and writable from the
  guest* at `/mnt/repo/.claude/tmp/<run-id>/...`.
- `cleanup()` retains `$RUN` (it shreds only `$CREDS_DIR`), so whatever
  lands there also outlives the run, inside the repo.

**How to apply:** for each new `$RUN/<thing>`, ask what it grants the
guest in live mode. PR #231 sited the single-file mount's wrap directory
(a **hard link** to an arbitrary host file, possibly outside the repo)
at `$RUN/mount-wrap/<tag>/<file>`, which hands the guest a writable
second path to the same inode and defeats that entry's `mode: ro` —
graded Medium there because `live` is opt-in and already grants repo rw.
The same lens applies to any future per-run artifact: a link, a copy of
a host secret, a socket, a spool file.

Related: the hard link is also why `ln` is used rather than `cp` (same
inode = rw write-through), so "move the wrap dir out of the repo" trades
against "a hard link cannot cross filesystems" — expect that tension in
the fix and do not recommend `$TMPDIR` blindly.
