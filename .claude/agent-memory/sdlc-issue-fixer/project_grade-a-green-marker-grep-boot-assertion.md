---
name: grade-a-green-marker-grep-boot-assertion
description: A boot assertion that greps a marker out of a guest console capture is green for three separable reasons — measure the marker's sole emitter, the image's version stamp, and which interpreter actually ran the harness — before writing prose about what it proved
metadata:
  type: project
---

`plugins/claude-vm/payload/test/host-acceptance.sh` proves a launcher step
ran by grepping a fixed marker string out of the guest console capture
(`(b4)` for issue #108's `claude-home/` seed). Running it and reporting
"green" is the cheap half; the PR body then makes three *structural*
claims that a green does not on its own establish. Each is one command.

- **Is the marker emitted anywhere else?** `grep -rn "<marker>"
  plugins/claude-vm/` — for (b4) the hits were the launcher's own success
  branch, the assertion, and one off-VM test. Read the emitting branch:
  (b4)'s runs only when the seeded-entry list is non-empty, so the green
  means an entry really installed, not merely that the block was reached.
- **Was the image stale?** The launcher's source is outside the
  image-identity hash, so criterion (a)'s version-stamp assertion is the
  only staleness control. `payload/build-guest-image.sh --print-version`
  prints the stamp (`debian-12-20250601+launcher27`); compare its
  `launcher<N>` against `git show origin/main:…build-guest-image.sh | grep
  LAUNCHER_LOGIC_REV`. That rules out a *pre-branch* launcher — it does
  NOT rule out an earlier commit on the same branch that already carried
  the same rev, so word the claim that way rather than "built from the
  launcher this branch emits".
- **Which bash ran it?** `bash -c 'echo $BASH_VERSION'`. On this host the
  PATH `bash` **is** `/bin/bash` 3.2, so a direct `./host-acceptance.sh`
  invocation and an explicit `bash …` invocation are the *same*
  interpreter — running it "the runbook way" to get a bash-5 run buys
  nothing here. This narrows
  [[run-the-guard-on-the-oldest-reachable-interpreter]]'s "`/bin/bash` vs
  `command -v bash` differ on macOS", which is not true of every box.

The 3.2 run emits `lib/config.sh: line NNNN: local: -A: invalid option`
on stderr from `claude_vm_render_guest_settings` while every assertion
still passes. It is on `origin/main` unchanged and is the same region
`config-test`'s standing 15 failures sit in — confirm that by running
`config-test.sh` and reading the FAIL *labels* (all `render:` /
`enabled-validate:`) rather than relaying the count from the PR body
you are editing.

Related: [[real-build-verification-not-unit-tests]],
[[real-boot-that-exercises-mounts-from-a-worktree]],
[[pr-body-is-a-swept-surface]].
