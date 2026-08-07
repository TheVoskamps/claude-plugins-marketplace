---
name: sourcing-order-decides-who-wins
description: "X's value always wins" is a claim about SOURCING/ASSIGNMENT ORDER, not about ownership — read the consumer's line numbers before letting it stand, and expect it copied to every operator surface.
metadata:
  type: feedback
---

A sentence of the form "the launcher's value always wins, so a config
that fights it can never take effect" is settled by *where* each
assignment is read, not by who owns the name. Open the consumer and
compare line numbers before the sentence survives a pass.

**Why:** PR #243 (claude-vm `env:`) shipped a gate refusing config
entries that name launcher-composed variables, with that rationale
restated on seven surfaces (`lib/config.sh` header + two `echo`
diagnostics, `claude-vm.sh` call-site comment, `payload/README.md`,
both `config-*.example.yml`, `skills/claude-vm/SKILL.md`, both config
wizards). It was backwards: the boot launcher sources `run.env` first
and the env files immediately after, so a config entry would have WON
and broken the boot. Only `CLAUDE_VM_LAST_CLAUDE_STATUS`, exported far
later, behaves the way the prose claimed. The *gate* was right, the
*reason* was false, and no test failed — the tests matched only the
diagnostic's first line, never the rationale line.

A reword sweep of that rationale is only half the fix. The *enumeration*
of the reserved set sits in the same sentence on the operator surfaces
(`skills/claude-vm/SKILL.md`, both wizards, both `config-*.example.yml`,
`claude-vm.sh`'s `claude_vm_check_env` call-site comment) and each one
still listed only run.env's names — the exception member was named on
`payload/README.md` and in `lib/config.sh` alone, so five surfaces
enumerated a set that was short by one and applied the majority rationale
to all of it. Fix the list and the reason together.

**How to apply:** when a doc says one writer beats another, grep the
consuming script for both assignments and order them. In `claude-vm`
specifically, the boot launcher's read order is run.env →
`/etc/claude-vm/bake-env` → `$CLAUDECREDS_MNT/env` → everything else,
and consumers (apt proxy, the `eval "set -- $CLAUDE_ARGS"`) run after
all three. Related: [[no-blanket-predicate-over-a-list]] — a rationale
copied to N surfaces is N claims, and fixing the obvious two looks
complete.
