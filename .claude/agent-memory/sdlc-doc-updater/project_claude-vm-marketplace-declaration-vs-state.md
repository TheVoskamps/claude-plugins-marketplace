---
name: claude-vm-marketplace-declaration-vs-state
description: claude-vm's marketplace prose splits into host-side DECLARATION framing (the derived-egress gate) and guest-side IMAGE-STATE framing (boot_plugin_phase, apt "all-baked"); a sweep that flattens both ways introduces errors, so check which side a sentence is on before rewording it.
metadata:
  type: project
---

Two framings coexist in `plugins/claude-vm`, and they are both correct:

- **Declaration framing (host side).** `claude_vm_boot_marketplace_egress_needed`
  in `payload/lib/config.sh` tests a boot-declared marketplace's name against
  `claude_vm_baked_marketplace_names` — the bake *declaration*. Since #226 the
  build only *tries* to pre-register a boot-declared marketplace, so the host
  cannot know the image state and the gate is deliberately conservative. Prose
  here must not say "already baked into the image".
- **Image-state framing (guest side).** `build-guest-image.sh`'s
  `boot_plugin_phase` step 1 genuinely reads the image: `plugin_marketplace_registered`
  shells out to `claude plugin marketplace list`. "the image does not already
  carry" is the right wording there and must survive the sweep.
- The apt paragraphs' "hard-secure all-baked config" (README, podman-mkosi.sh's
  `apt` justification, `config-boot.example.yml`) are about apt packages, which
  really are image bytes. Leave them.

**Why:** issue #226's fix rounds reworded the gate's prose plugin-wide, and the
tempting next step — making every "baked" read "bake-declared" — would falsify
the guest-side and apt comments.

**How to apply:** before rewording any claude-vm "baked"/"already carries"
sentence, ask which side of the host/guest seam its code lives on. The
markdown surfaces (`payload/README.md` derived-egress + boot-path sections,
`skills/claude-vm/SKILL.md` `.add_marketplace_uris_to_allowlist` bullet) were
already carrying the declaration wording before the shell sweep landed, so a
prose-only fixer round on those shell files is usually a doc-updater no-op —
verify against the code and say so rather than re-editing. Related:
[[claude-vm-config-redesign-stale-comment-classes]].
