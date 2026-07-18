---
name: claude-vm-parallel-allowlist-knobs
description: claude-vm has multiple independent add_*_uris_to_allowlist knobs (packages.add_apt_uris_to_allowlist, claude.plugins.add_marketplace_uris_to_allowlist); never describe one as controlling the other.
metadata:
  type: project
---

claude-vm's config carries more than one `add_*_uris_to_allowlist`
scalar, each gating a *different* egress-derivation step at boot:
`packages.add_apt_uris_to_allowlist` (apt/Debian-mirror egress, issue
#106) and `claude.plugins.add_marketplace_uris_to_allowlist`
(marketplace/plugin egress, issue #103). They share the same
auto/always semantics and are documented with "same semantics as
X" / "X's analogue" cross-references — but they are separate scalars,
each read independently by its own gate function
(`claude_vm_boot_apt_egress_needed` for the apt one).

**Why:** a PR-authored comment in `config.example.yml` for issue #106
claimed `packages.add_apt_uris_to_allowlist` "controls BOTH the
build-time marketplace/plugin URIs ... AND this boot-time apt
egress" — conflating the parallel-knob cross-reference with a
shared-control claim. Caught by grepping every
`add_apt_uris_to_allowlist` / `add_marketplace_uris_to_allowlist`
occurrence and reading `claude.plugins.add_marketplace_uris_to_allowlist`'s
own comment, which correctly said "analogue of", not "controlled by".

**How to apply:** whenever a claude-vm doc pass touches either
`add_apt_uris_to_allowlist` or `add_marketplace_uris_to_allowlist`,
grep for both names across `config.example.yml`, `payload/README.md`,
and every `skills/claude-vm*/SKILL.md`, and verify each occurrence
describes them as parallel/independent (cross-referenced by shared
semantics) — never as one controlling the other.
