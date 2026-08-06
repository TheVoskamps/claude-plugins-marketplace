---
name: reviewer-exclusivity-premise-is-measurable
description: A finding's "nothing else reaches X" premise is a measurable claim about the rest of the system — enumerate the real consumers before repeating it in prose or letting it justify a placement decision
metadata:
  type: project
---

A review finding usually carries an **exclusivity premise** underneath
its recommendation: "this is the only member the operator can hit",
"no other caller touches that path", "removing this makes the launch
work". The finding's *defect* is normally measured; the premise
usually is not. It is a claim about the rest of the system, so it is
falsifiable in one grep of the sites that consume the value.

**Why:** PR #231 round 5 filed the single-file wrap dir as "the one
member an operator can hit with every built-in path clean, since in
the git-repo + `live` shape no built-in device touches `$TMPDIR`".
Enumerating every vfkit argument in `claude-vm.sh` showed
`--device virtio-net,unixSocketPath=$GVPROXY_SOCK` is a `mktemp -d`
under `$TMPDIR` on **every** launch, and vfkit v0.6.4 splits it on a
comma exactly like `sharedDir=` (`unknown option for virtio-net
devices: …`; `efi,variable-store=`, `virtio-blk,path=` and
`virtio-serial,logFilePath=` behave the same). So the guard is an
earlier, cause-naming abort, never a rescue — and the placement
argument I had built on the premise ("checking at the assignment would
refuse a launch that would otherwise work") was false: every such
launch was already doomed.

**How to apply:** before you copy a finding's premise into a code
comment, a README paragraph or a PR-body bullet, grep the one
construct the premise quantifies over (here: `grep -n -- "--device"`
plus the assignment of each interpolated variable) and run the
consumer on the edge value. If the premise falls, the fix usually
still stands but its *stated benefit* changes — reword every surface
to the benefit you can prove, fix the enumeration the premise came
from, and report the correction to the parent rather than shipping the
reviewer's sentence unexamined.

Related: [[verify-a-predicted-verdict-before-implementing-it]],
[[a-findings-world-state-is-a-snapshot]],
[[shared-predicate-list-is-one-claim]],
[[pr-body-is-a-swept-surface]].
