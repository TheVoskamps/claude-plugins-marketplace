---
name: github-setup-docs-locality
description: Where gh-repo-setup-protection behavior is documented, and what is NOT stale when its gate logic changes
metadata:
  type: project
---

The `gh-repo-setup-protection` skill's behavior (incl. the
dependency-install-gate) is documented almost entirely inside its own
`plugins/github-setup/skills/gh-repo-setup-protection/SKILL.md`. That
SKILL.md is the skill's primary doc and is updated by the
developer/fixer as part of the code change, not by doc-updater.

**Why:** the repo keeps skill behavior co-located in each SKILL.md
rather than in separate prose docs. Other markdown only references the
skill by *name*, not by behavior:

- `plugins/github-setup/payload/README.md` — describes the gate
  generically ("dependency-install-gate (workflow + drift-check
  script)"); does not name job count or package managers.
- top-level `README.md` — plugin-level blurb ("branch protection")
  only.
- `docs/plugin-migration-plan.md` — skill-name table rows only.

**How to apply:** when a gh-repo-setup-protection code change lands
(e.g. the #111 split of the install-gate from 2 jobs {npm,pip} to 4
{npm,pip,pnpm,yarn}), do NOT expect to edit those three files — their
references are behavior-agnostic and stay accurate. Verify the SKILL.md
sweep is complete, then confirm no stale "npm/pip" or "two jobs"
framing leaked into other docs. Sibling skill SKILL.md files
(`gh-repo-setup-public`, `gh-repo-setup-pr-automation`, `gh-create-app`)
do not describe the gate. Note: grepping for `pip` in this plugin's
docs yields false positives from "pipe"/"pipes" (the .pem-into-`gh
secret set` flow).

**Counterexample (#177, PR #178):** the developer added a new
categorical exemption (pnpm `catalog:` specs) to
`dependency-pinned-gate.sh`'s classifier and kept the script's own
header comment fully current, but did NOT touch SKILL.md — the
exemption-family enumeration appears **three times** in that file
(a short-form list near the gate's Step 5c-pinned description, a
long-form paragraph in the pinned-gate deep-dive section, and a
short-form list again in the quick-reference gotchas section near the
end), and all three needed the new exemption added by hand. So "usually
already current" holds for the sibling script/workflow doc comments but
not reliably for SKILL.md's own prose — always grep SKILL.md for the
exemption list's other members (`peerDependencies`, `file:`,
`workspace:`) when a pinned-gate classifier PR lands, since a new
exemption category is exactly the kind of change that needs sweeping
across all repeated enumerations, not just adding once.
