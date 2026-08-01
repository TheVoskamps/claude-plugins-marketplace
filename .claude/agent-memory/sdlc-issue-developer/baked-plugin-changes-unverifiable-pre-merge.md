---
name: baked-plugin-changes-unverifiable-pre-merge
description: A claude-vm guest bakes plugins by cloning the marketplace's DEFAULT branch, so a plugin change on a feature branch can never be verified in a real guest until it is on main -- don't burn a 7-minute image build trying.
metadata:
  type: project
---

`claude plugin marketplace add <git-url>` clones the marketplace's
**default branch**. There is no ref/branch/tag selection. So when a
claude-vm bake config lists `<plugin>@thevoskamps`, the guest image
gets whatever version is on `main` — never your feature branch.

**Why:** this makes "verify it in a real guest boot" structurally
impossible for any plugin change before it merges. Building the image
from an issue branch installs the OLD plugin version and proves
nothing about the diff. Confirmed while doing issue #216 (guardrails
0.9.14 -> 0.9.15): a real guest build would have baked 0.9.14, the
exact version missing the fix.

**How to apply:** when an issue's acceptance says "verified in a real
guest", do NOT spend the ~7-minute image build. Instead:

1. Verify every layer the guest depends on *outside* the guest, on the
   guest's real platform — see
   [[claude-vm-real-build-and-boot-is-doable]] for the arm64 container
   recipe. For a hook that means: extract the shipped command string
   from `hooks.json` with `jq -r`, run it under `/bin/sh` with the
   real event JSON on stdin, in a `linux/arm64` Debian container with
   the plugin dir bind-mounted as `CLAUDE_PLUGIN_ROOT`.
2. Report the guest-integration remainder as **NOT VERIFIED** in the
   PR headline, with the structural reason (this memory), so it does
   not read as laziness.
3. Hand the human a post-merge test plan with exact commands —
   including the plugin's NEW version number in the cache path
   (`~/.claude/plugins/cache/<mkt>/<plugin>/<version>/...`), since the
   version bump moves that path.

Corollary for anything gated on a *marketplace* bump rather than a
plugin bump: same constraint, same workaround.
