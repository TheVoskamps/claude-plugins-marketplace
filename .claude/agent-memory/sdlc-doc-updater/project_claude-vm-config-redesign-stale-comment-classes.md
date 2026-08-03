---
name: claude-vm-config-redesign-stale-comment-classes
description: after a claude-vm config-model redesign (e.g. #179's bake/boot split), grep for the OLD config filename and OLD deleted function names across claude-vm.sh/lib/config.sh/provisioners/tests even when the developer's README pass looks thorough.
metadata:
  type: project
---

Issue #179 (single `config.yml` -> four-file bake/boot split, whole-file
raw-byte image-identity hash replacing `claude_vm_build_config_json` /
`claude_vm_build_hash` / `claude_vm_build_config_is_empty`) shipped with
an exceptionally thorough developer doc pass — `payload/README.md` and
both config-wizard SKILL.md files were already fully updated and internally
consistent. Despite that, a `grep -rn "config\.yml\b"` and a grep for the
deleted function names across the plugin still turned up real defects:

- `claude-vm.sh`'s own file-header comment and its image-identity block
  comment still described the pre-#179 model (hadn't been touched even
  though the code right below them had been rewritten).
- Two **user-facing error messages** (`echo "claude-vm: ... config.yml"`)
  pointed operators at the legacy filename for keys that are now boot-tier
  (`egress.allow`, `claude.signing_key_fingerprint`) — these are easy to
  miss because they're runtime strings, not structural doc comments.
- `lib/config.sh`'s own top-of-file header still called itself a
  "two-tier" loader.
- Three **security-sensitive** comments (in `podman-mkosi.sh`,
  `config-test.sh`, `podman-mkosi-test.sh`) documenting the untrusted-input
  provenance of `apt_sources`/`name` still cited `.claude-vm/config.yml`
  instead of the now-correct `.claude-vm/config-bake.yml` — stale security
  provenance comments are worse than merely cosmetic since a future reader
  may under- or over-trust the wrong file.
- The README's helper-function list still documented three functions
  (`claude_vm_build_config_json`/`_build_hash`/`_build_config_is_empty`)
  that #179 deleted outright, replaced by `claude_vm_file_identity_hash`.

**Why:** a developer's own diff-adjacent comments (right next to the code
they changed) get updated reliably; comments and messages *elsewhere* in
the same file, or in sibling files that merely reference the changed
concept, do not. A thorough README pass is not a substitute for a
grep-based sweep.

A further class: `lib/config.sh` helper headers routinely name their
*downstream consumer* ("these are already registered inside the image, so
the boot path only has to ADD the rest"), and that clause rots
independently of the code. `payload/README.md`'s helper bullets repeat the
same consumer claim verbatim, so a wrong one is wrong in two places. A
`grep -rn <helper_name>` settles who actually calls a helper in one call;
the prose around the helper never does.

Another class, seen on #226 (bake-time marketplace registration went from
unconditional to per-entry): prose that describes a *derived-egress gate*
by the state it approximates rather than the state it tests. Both
`payload/README.md`'s `claude_vm_boot_marketplace_egress_needed` bullet and
`skills/claude-vm/SKILL.md`'s `add_marketplace_uris_to_allowlist` bullet
said the gate fires for "a marketplace the image does not carry" / "not
already baked". The gate has always read the bake *declaration*; before the
change the two were equivalent, after it they diverge, and the gate is
deliberately conservative because the host cannot know whether the build's
best-effort pre-registration succeeded. When a guarantee is relaxed, reread
every gate description for approximations that were previously exact.

That one gate is described in THREE places, and an earlier doc round fixed
only two: `payload/README.md`'s helper bullet for
`claude_vm_boot_marketplace_egress_needed` (~line 400), `payload/README.md`'s
separate *Derived egress* paragraph much further down in the guest-image
section (~line 670), and `skills/claude-vm/SKILL.md`'s
`add_marketplace_uris_to_allowlist` bullet. Grep the *criterion wording*
("not already baked", "already baked", "the image does not carry"), not the
helper name — the Derived egress paragraph never names the helper, so a
name-based grep misses it entirely.

**Leniency side of the same change:** when a per-entry policy gains skip
paths, count them in the code and check the prose enumerates the same set.
On #226 the provisioner grew three lenient paths for a boot-declared
marketplace (no `url`, the add fails, the add registers a name that does not
match) while both README and SKILL.md still described only the
url-unreachable one.

**How to apply:** after any claude-vm config-schema or identity-hashing
redesign, grep the whole plugin (not just the README) for: the OLD
filename/keyword the redesign retired, and the exact names of any deleted
functions. Check hits in `claude-vm.sh` file headers/block comments (not
just call sites), user-facing `echo ... >&2` messages (operators act on
these directly), and any comment describing untrusted-input provenance in
the mkosi provisioner/tests. See also
[[claude-vm-four-file-config-and-per-run-clone]] for the #179 design
itself.
