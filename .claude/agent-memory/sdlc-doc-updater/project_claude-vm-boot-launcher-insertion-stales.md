---
name: claude-vm-boot-launcher-insertion-stales
description: inserting a step into claude-vm's emitted boot launcher stales the NEXT phase's "ORDERING: first thing after X" note and the claudecreds/CREDS_DIR content enumerations in the two sibling headers.
metadata:
  type: project
---

A claude-vm PR that adds a step to the boot launcher emitted by
`payload/build-guest-image.sh` reliably leaves two things behind, both
away from the diff:

- The **next phase's `ORDERING:` note**. The extra-mount block says
  "first thing after run.env, before the credential/seed/settings
  install" — issue #135 inserted the env source-and-export step between
  them and did not touch it. Grep `ORDERING:` in
  `build-guest-image.sh` after any launcher insertion.
- The **claudecreds content enumerations**. Three headers list what the
  transient share carries: `claude-vm.sh`'s run.env `CLAUDECREDS_TAG`
  comment (the developer updates this one, it is next to the change),
  `claude-vm.sh`'s `CREDS_DIR=` header ~450 lines earlier, and
  `build-guest-image.sh`'s `CLAUDECREDS_MNT=` header. The latter two
  also assert the launcher "installs each into `$HOME/.claude/`", which
  a file the guest only *sources* falsifies.

**Why:** the emitted launcher is one long heredoc, so phase-ordering
prose sits hundreds of lines from any insertion point, and the
credential-share enumerations live in a different file from the feature.

**How to apply:** on any claude-vm launcher change, grep `ORDERING:`,
`CLAUDECREDS`, and `CREDS_DIR` before deciding a pass is complete.
Comment-only edits inside the launcher heredoc need no
`LAUNCHER_LOGIC_REV` bump (the rev tracks behavior; the launcher source
is not in the image-identity hash), but do re-run
`payload/test/boot-launcher-test.sh`, which parses the emitted script.
See also [[claude-vm-config-redesign-stale-comment-classes]].
