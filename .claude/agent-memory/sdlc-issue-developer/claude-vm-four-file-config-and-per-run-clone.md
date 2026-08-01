---
name: claude-vm-four-file-config-and-per-run-clone
description: claude-vm's config model was redesigned in issue #179 -- four bake/boot files replace the single config.yml, image identity is a whole-file raw-byte hash of the BAKE files, and the immutable base .raw is APFS-cloned per run.
metadata:
  type: project
---

Issue #179 redesigned claude-vm's config + image model. Key facts a
future editor MUST know before touching `payload/lib/config.sh`,
`payload/claude-vm.sh`, or the config wizards:

**Four config files, all optional** (was: single `config.yml` per tier):
`config-bake.yml` + `config-boot.yml`, at `~/.config/claude-vm/` (global)
and `<repo>/.claude-vm/` (repo). Placement rule: a key that changes BYTES
in the guest `.raw` goes in a BAKE file; a run-time key goes in a BOOT
file. **Schema flattening:** a bake file's top-level `packages:` is a flat
LIST that becomes internal `.packages.bake`; a boot file's `packages:`
becomes `.packages.install_at_boot`; each file's `apt_sources:` unions
onto `.packages.apt_sources`. `claude_vm_compose_effective_config`
normalizes the four files (`claude_vm_normalize_config_file <file> bake|boot`)
then reuses the OLD two-file `claude_vm_merge_config` primitive to merge
tier bake+boot, then global-under-repo. Downstream accessors
(`claude_vm_egress_hosts`, `claude_vm_apt_sources`,
`claude_vm_list_items '.packages.bake'`, etc.) are UNCHANGED -- they read
the internal merged-doc keys the normalization produces.

**Image identity is now WHOLE-FILE, RAW-BYTE hashing of the BAKE files**
(`claude_vm_file_identity_hash`), NOT the old key-picked
`claude_vm_build_config_json`/`_build_hash`/`_build_config_is_empty` (all
DELETED). No canonicalization: list order, key order, whitespace, and a
trailing-newline toggle all change the hash (the toggle is the documented
force-rebuild lever). `claude_vm_image_identity_segments` now takes the two
BAKE FILES; the repo segment's PRESENCE is gated on the repo-bake FILE
EXISTING (not its content) -- a missing global bake file hashes to the
`00000000` sentinel. `claude_vm_bake_config_json`/`_bake_hash` still exist
but ONLY as the build-CONTENT canonicalizer (`CLAUDE_VM_BAKE_CONFIG`), no
longer the identity.

**apt_sources union+dedup by name** across all four files
(`claude_vm_check_apt_sources_conflicts`): identical name+content
collapses; same name with differing `{repo,key_url}` ABORTS the launch.
The boot render skips names already baked (`claude_vm_boot_apt_sources`
filters against `claude_vm_baked_apt_source_names`).

**Immutable base + per-run clone** (`claude-vm.sh`): the cached base `.raw`
is NEVER attached to a VM. `cp -c "$GUEST_IMAGE" "$GUEST_IMAGE_CLONE"`
(APFS zero-copy, fallback to plain `cp`) makes a per-run clone at
`$RUN/guest-clone.raw`; vfkit boots the CLONE. `cleanup()` captures the
trap-time status, `sync`s before the VM stop (vfkit's routine
`forcing stop` can tear writes), and discards the clone on clean exit /
retains it on abnormal exit. `VM_EXIT_STATUS` is captured around the vfkit
call (`set +e` ... `VM_EXIT_STATUS=$?` ... `exit "$VM_EXIT_STATUS"`).

**Migration:** a legacy single-file `config.yml` is NOT read. The launcher
calls `claude_vm_detect_legacy_config` for both tiers and ABORTS with a
migration message (chosen from the acceptance criteria's fail-with-message
option, not a silent compat path).

**RECORDED FACT (do not presume a mechanism):** #106 observed a booted
shared read-write image with every `/var/lib/apt/lists` Packages index at
0 BYTES while InRelease files stayed valid (apt reported Hit, knew zero
packages, unrecoverable by plain `apt-get update`). Pristine built images
carried no list files (exonerating mkosi); only observed in the era when
boot-time `apt-get update` was already failing on the keyring bug #106
fixed. The per-run-clone design removes the shared-writable image this
lived on. Recorded in config-test.sh Test 28.

**NOT verified by a real VM boot** in the implementing run; shell/config
tests (config-test.sh: 205 pass) were the only coverage there. The
parenthetical that used to sit here -- "throwaway worktree cannot
build+boot" -- is WRONG and was disproved in issue #107, which did both
from a throwaway worktree. See
[[claude-vm-real-build-and-boot-is-doable]] for the recipe, and
[[unit-tests-are-not-real-runs]] for why it still matters.
