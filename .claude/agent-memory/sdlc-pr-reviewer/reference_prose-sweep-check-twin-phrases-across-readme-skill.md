---
name: prose-sweep-check-twin-phrases-across-readme-skill
description: when reviewing a claude-vm prose-consistency sweep (exec-claude / exec'd-shell retirement), the README.md and skills/claude-vm/SKILL.md carry near-verbatim twin sentences; a sweep that converts a phrase in README often leaves the identical twin in SKILL.md unconverted — diff the two files for the same phrase before trusting an "all sites fixed" completeness claim.
metadata:
  type: reference
---

claude-vm's `payload/README.md` and `skills/claude-vm/SKILL.md` contain
large blocks of near-verbatim parallel prose (boot-launcher description,
credential/seed install, install-health check). A prose-sweep commit
that claims "all N sites fixed" repeatedly converts the README copy and
leaves the SKILL.md twin stale.

Concrete instance (PR #180, commit retiring "exec'ing claude" prose):
the commit converted README.md:263 "before exec'ing `claude`" ->
"before launching `claude`" and README.md:375 "execs the host-verified
claude" -> "runs the host-verified claude", but left the verbatim twins
SKILL.md:704 "before exec'ing `claude`" and SKILL.md:474 "then execs the
host-side GPG-verified `claude` binary" unconverted.

**How to apply:** when reviewing any claude-vm doc-consistency sweep,
after listing the converted phrases in the diff, grep the SAME phrase in
BOTH README.md and SKILL.md. A hit in one but not the other is a
sweep-the-class miss regardless of an "all sites" completeness claim.
See [[checkout-pr-branch-before-exercising]] for the branch-checkout
prerequisite before grepping shipped code.

Legit survivor classes that are NOT findings: changelog stanzas in
build-guest-image.sh's BASE_OS_REV block (frozen historical records),
negative assertions ("runs claude as a CHILD, not `exec`"), explicit
retrospectives ("the previous shape exec'd the shell", "pre-#179 model
exec'd claude"), and generic non-claude execs (tinyproxy, vfkit,
libexec, ExecStart). Heredoc-internal (emit_boot_launcher, ~356-1000 in
build-guest-image.sh) stale-exec comments are a separate scope: touching
them changes emitted-launcher bytes and forces a LAUNCHER_LOGIC_REV bump,
so a host-side-only prose commit legitimately leaves them.
