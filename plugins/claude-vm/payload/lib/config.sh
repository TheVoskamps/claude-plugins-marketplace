#!/usr/bin/env bash
#
# config.sh -- four-file (bake/boot per tier) YAML config loader + layering
# for claude-vm.
#
# Sourced by claude-vm.sh. Also directly testable: the layering logic is pure
# (input files -> one merged YAML on stdout) with no VM, no network, and no
# host mutation, so payload/test/config-test.sh exercises it in isolation.
#
# Four files, all optional (issue #179): a bake file and a boot file per tier
# -- global bake/boot at ~/.config/claude-vm/, repo bake/boot at
# <repo>/.claude-vm/. A bake file's top-level `packages:` is a flat list
# baked into the image; a boot file's top-level `packages:` is a flat list
# installed at boot; each file's `apt_sources:` unions in. Each file type has
# ONE schema (its example file), read as written -- merging happens WITHIN a
# tier (global+repo bake -> MERGED_BAKE; global+repo boot -> MERGED_BOOT),
# never across tiers. See the "Four-file config" section below.
#
# Layering semantics (from issue #6, extended by issue #103), applied within
# each tier's merge:
#   - Scalars (cpus, mem, guest_image, repo.mount, repo.copy_back,
#     proxy.cmd, proxy.port, proxy.host_alias, update_at_boot,
#     add_apt_uris_to_allowlist, claude.permission_mode,
#     claude.plugins.update_at_boot,
#     claude.plugins.add_marketplace_uris_to_allowlist,
#     github.auth): repo overrides global; global fills gaps.
#   - Scalar MAPS (claude.plugins.enabled, env.set): repo-over-global PER KEY
#     -- each entry follows the scalar repo-wins rule independently, so a repo
#     can flip one plugin's enabled state, or one environment variable's value,
#     without restating the global map. See claude_vm_merge_config below.
#   - Lists (egress.allow, mounts, packages, apt_sources,
#     claude.permissions.allow/ask/deny, claude.marketplaces,
#     claude.plugins.bake, claude.plugins.install_at_boot, env.copy, env.files
#     -- see CLAUDE_VM_LIST_KEYS below): MERGED -- union of global + repo
#     entries (de-duplicated, order: global entries first, then repo entries
#     not already present).
#
# All four files are OPTIONAL. A missing file is treated as `{}` (empty
# document), so any combination resolves cleanly.
#
# Secrets are never read from or written to these files. The guest
# authenticates with the host's claude.ai OAuth credential, which the
# launcher extracts from the macOS Keychain at launch; see SKILL.md. A
# third-party API key reaches the guest the same way -- by REFERENCE, not by
# value: `env.copy` names a host environment variable and `env.files` names a
# host `.env` file, both read at launch (issue #135). `env.set` is for
# non-secret literals only, since its values ARE the committed config.
#
# Requires: yq (v4+, the Go/mikefarah implementation). Detected at
# source time so callers fail fast with an actionable message.

set -uo pipefail

# Default config locations (issue #179 -- FOUR files, all optional). The config
# is split into a BAKE file (changes image bytes) and a BOOT file (changes
# launcher/VM wiring at run time) per tier. Overridable via env for testing.
#
#   global bake: ~/.config/claude-vm/config-bake.yml
#   global boot: ~/.config/claude-vm/config-boot.yml
#   repo   bake: <repo>/.claude-vm/config-bake.yml   (resolved by the launcher)
#   repo   boot: <repo>/.claude-vm/config-boot.yml   (resolved by the launcher)
: "${CLAUDE_VM_GLOBAL_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm}"
: "${CLAUDE_VM_GLOBAL_BAKE_CONFIG:=$CLAUDE_VM_GLOBAL_CONFIG_DIR/config-bake.yml}"
: "${CLAUDE_VM_GLOBAL_BOOT_CONFIG:=$CLAUDE_VM_GLOBAL_CONFIG_DIR/config-boot.yml}"
# The legacy single-file global config, kept ONLY for migration detection (see
# claude_vm_detect_legacy_config); it is NOT read as config anymore.
: "${CLAUDE_VM_GLOBAL_LEGACY_CONFIG:=$CLAUDE_VM_GLOBAL_CONFIG_DIR/config.yml}"
# CLAUDE_VM_REPO_BAKE_CONFIG / CLAUDE_VM_REPO_BOOT_CONFIG are resolved per-run
# relative to the repo root by the launcher (<repo>/.claude-vm/config-{bake,boot}.yml);
# tests set them directly.

# Detect a legacy single-file config (config.yml) where a bake/boot pair is now
# expected, and emit an actionable migration message. The design's chosen
# migration path is FAIL-WITH-MESSAGE (Acceptance: "Existing single-file configs
# either keep working through a compat path or fail with a clear migration
# message -- no silent misreads"). We take the explicit-abort branch so a stale
# single file is never silently ignored (which would drop every knob it set).
#
#   $1 -- tier label for the message ("global" or "repo <name>")
#   $2 -- the legacy config.yml path to check
#   $3 -- the config dir the bake/boot pair belongs in (for the message)
# Returns 0 (exit) when NO legacy file is present (nothing to migrate); returns
# 1 after printing the migration message when a legacy config.yml exists.
claude_vm_detect_legacy_config() {
  local tier="$1" legacy="$2" dir="$3"
  [ -n "$legacy" ] && [ -f "$legacy" ] || return 0
  echo "claude-vm: found a legacy single-file $tier config at '$legacy'." >&2
  echo "claude-vm: claude-vm now splits config into TWO files per tier (issue #179):" >&2
  echo "claude-vm:   $dir/config-bake.yml  -- keys that change the guest IMAGE (packages baked in," >&2
  echo "claude-vm:                            apt_sources, image.root_headroom_mb)" >&2
  echo "claude-vm:   $dir/config-boot.yml  -- keys applied at run time (egress, mounts, proxy, cpus," >&2
  echo "claude-vm:                            mem, packages installed at boot, update_at_boot, claude.*," >&2
  echo "claude-vm:                            github.*, add_apt_uris_to_allowlist)" >&2
  echo "claude-vm: The single '$legacy' is NOT read anymore -- reading it silently would drop knobs" >&2
  echo "claude-vm: whose bake/boot placement it cannot express. Split it into the pair above, then" >&2
  echo "claude-vm: remove or rename '$legacy'. The /claude-vm-config-global and /claude-vm-config-repo" >&2
  echo "claude-vm: wizards write the pair for you. See payload/config-bake.example.yml /" >&2
  echo "claude-vm: config-boot.example.yml for the split." >&2
  return 1
}

# Hardcoded fallbacks for scalars the user did not set in EITHER layer.
# These mirror the reference launcher's env-var defaults.
CLAUDE_VM_DEFAULT_CPUS=4
CLAUDE_VM_DEFAULT_MEM=8192
CLAUDE_VM_DEFAULT_REPO_MOUNT=clone
CLAUDE_VM_DEFAULT_REPO_COPY_BACK=local
CLAUDE_VM_DEFAULT_PROXY_PORT=3128
CLAUDE_VM_DEFAULT_PROXY_HOST_ALIAS=192.168.127.254
# claude.version: which claude binary the host-side verified cache fetches
# (stable|latest|<pinned>). `stable` is the conservative default. Consumed
# by lib/claude-cache.sh; defined here so all scalar defaults live together.
CLAUDE_VM_DEFAULT_CLAUDE_VERSION=stable

# Guest-capability schema defaults (issue #103): packages, Claude
# permissions/marketplaces/plugins, and GitHub auth. See
# payload/config-bake.example.yml, payload/config-boot.example.yml, and
# skills/claude-vm/SKILL.md for the full annotated schema and semantics.
CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT=true
CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST=auto
CLAUDE_VM_DEFAULT_CLAUDE_PERMISSION_MODE=bypassPermissions
CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_UPDATE_AT_BOOT=true
CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_ADD_MARKETPLACE_URIS_TO_ALLOWLIST=auto
CLAUDE_VM_DEFAULT_GITHUB_AUTH=none

# Extra-mount defaults + reserved names (issue #157).
#
# EVERY extra mount is READ-WRITE, and there is no `mode:` key. Read-only cannot
# be enforced anywhere on this stack, so offering it under the name `ro` would
# be a false promise:
#
#   - vfkit's virtio-fs device has no read-only option at all. It validates
#     device option keys strictly, and every spelling is rejected as an UNKNOWN
#     key -- verified against vfkit v0.6.4:
#       --device virtio-fs,...,readOnly=true
#         -> Error: unknown option for virtio-fs devices: readOnly
#     (`readonly` and a bare `ro` fail the same way). The block-backed devices
#     DO carry the key -- `virtio-blk,...,readonly=true` fails on the VALUE
#     ("unexpected value for virtio-blk 'readonly' option"), so there the key
#     itself is recognized -- which is what makes the virtio-fs gap specific
#     rather than a quirk of the option parser. vfkit drives
#     Virtualization.framework directly, so there is no virtiofsd in between to
#     hand a read-only export to either.
#   - So the host exports every share read-write, and the guest session runs as
#     ROOT (autologin getty, HOME=/root). A `-o ro` passed to the guest's own
#     `mount` is therefore guest-side only and undoable from inside by the very
#     session it would be restraining.
#
# Issue #233 carries the enforced-read-only design (a read-only block device, so
# the HYPERVISOR refuses the write and guest root is irrelevant) and will pick
# its own config surface, which need not be spelled `mode:`. Until then an
# explicitly-supplied `mode:` is a hard abort at config load
# (claude_vm_check_mounts) rather than an ignored key: silently accepting it
# would leave an operator believing they had read-only when they do not.
#
# The guest mountpoint defaults to `<CLAUDE_VM_GUEST_MOUNT_ROOT>/<tag>`; a
# per-entry `path:` overrides it.
CLAUDE_VM_GUEST_MOUNT_ROOT=/mnt
# The virtio-fs tags the launcher ALWAYS attaches (claude-vm.sh's vfkit
# invocation) and the guest image's baked /etc/fstab already mounts
# (provisioners/podman-mkosi.sh). An extra mount reusing one of these names
# would attach a second device under a tag the fstab also claims -- the guest
# would mount whichever the kernel enumerated, so the repo/run-config/binary/
# credential share the rest of the boot depends on could silently become the
# operator's own directory. Space-delimited, matched with a space-padded `case`
# so no name is a prefix-match of another.
CLAUDE_VM_RESERVED_MOUNT_TAGS="repo runconfig claudebin claudecreds"
# The guest path the boot launcher stages a single-file mount's wrap share at
# before bind-mounting the one file onto its target -- build-guest-image.sh's
# MOUNT_WRAP_MNT, restated here because the boot launcher is a script baked
# into the image and cannot source this file. Kept in the reserved-mountpoint
# set for the same reason the built-in shares are, and tested by the same
# OVERLAP relation as the rest of that set: an operator `path:` landing ON it
# or ABOVE it would shadow the staging directory every single-file mount passes
# through, and one landing INSIDE it would sit under a tmpfs path the boot
# launcher mkdirs and mounts a share over per single-file entry. The two
# spellings must stay equal; each side's comment names the other.
CLAUDE_VM_GUEST_WRAP_MOUNT=/run/claude-vm/mount-wrap

# The guest OS's OWN directories. Linux STACKS a mount: mounting over an
# occupied path does not merge or fail, it hides what was there for the life of
# the VM. So an extra mount landing on a guest system path takes the OS's own
# files out from under the boot -- `path: /etc` hides every configuration file,
# `path: /usr` hides the boot launcher itself
# (/usr/local/lib/claude-vm/boot-launcher.sh) and every binary, `path: /root`
# hides the session's HOME before the credential seed writes /root/.claude into
# it. The mount phase runs FIRST in the boot launcher, so the damage always
# lands before the phase that would have noticed, and surfaces later as
# something unrelated.
#
# This set is the HOST's half of the guard and is necessarily a DENYLIST: the
# launcher cannot read the guest image's filesystem, so it cannot enumerate what
# is actually there. Its job is to fail fast, before the VM starts, naming the
# config entry. The guest's own occupancy check (build-guest-image.sh's
# boot_mount_phase) is the real observation and catches what a denylist cannot.
#
# Membership was measured, not recalled: a stock debian:12 rootfs (the guest's
# base) was enumerated directory by directory, and /bin /dev /etc /lib /proc
# /root /run /sbin /sys /usr /var all carry content while /boot /home /media
# /mnt /opt /srv /tmp ship empty. /boot, /home and /tmp are in the set anyway --
# /boot is populated in a bootable image rather than in a container rootfs,
# /home and /tmp are OS-owned working areas, and /tmp in particular must stay
# writable and private for the session. The /lib{32,64,x32} spellings do not
# exist on arm64 (the guest's architecture) and are listed for the amd64 shape.
#
# DELIBERATELY ABSENT: /mnt, /media, /opt, /srv. /mnt is claude-vm's OWN mount
# root -- the default mountpoint is /mnt/<tag>, so denying it would deny the
# default -- and its built-in shares are already covered by the reserved-path
# set above. /media, /opt and /srv are the FHS's mount-something-here
# directories and ship empty, which is exactly what makes them a safe
# destination for an operator's share.
#
# Space-delimited, matched by the OVERLAP relation rather than by membership,
# for the same reason the reserved mountpoints are.
CLAUDE_VM_GUEST_SYSTEM_PATHS="/bin /boot /dev /etc /home /lib /lib32 /lib64 /libx32 /proc /root /run /sbin /sys /tmp /usr /var"
# The subset of the above whose CONTENTS are user data rather than package
# files: the guest session's HOME (/root -- claude runs as root), the
# conventional user-home root, and the scratch area. A SINGLE-FILE mount may
# land inside one of these, which is what keeps issue #157's own shipped
# acceptance case (`path: /root/.gitconfig`) working; inside any OTHER system
# path every file belongs to a package, so a single-file mount there is a
# mount over a system FILE and is rejected.
#
# A file bind replaces exactly one file, while a directory mount hides an entire
# subtree -- that asymmetry is the whole reason the two shapes do not get the
# same rule.
CLAUDE_VM_GUEST_USER_FILE_PATHS="/home /root /tmp"

# image.root_headroom_mb (issue #106 real-run fix): extra MiB the guest root
# partition is sized ABOVE the measured/estimated base image content, so a
# live session has room to grow without hitting ENOSPC. A real guest boot hit
# ENOSPC twice in one short session on the previously auto-sized (~991 MB)
# root, which left only ~140 MB free over an ~850 MB base -- consumed by the
# boot-time apt working set (up to ~250 MB pre-diet, ~50 MB post-diet; see
# podman-mkosi.sh/build-guest-image.sh) plus ~44 MB of observed session growth
# (journald and/or the in-guest claude's home; root cause not pinned down) in
# a SHORT session -- a longer one grows more. 1024 MB is roughly 20x that
# observed short-session growth and covers several rounds of mid-session
# `apt-get install` on top of the post-diet boot working set, so a stock
# session (update_at_boot: true, the default) should not hit ENOSPC. Chosen
# to be generous rather than tight: the human's directive is that claude-vm
# must WORK out of the box, and disk is cheap relative to a bricked session.
CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB=1024

# Resolve the gvproxy binary path. gvproxy ships INSIDE the podman
# Homebrew formula at <prefix>/libexec/podman/gvproxy and is NOT placed
# on PATH by a stock `brew install podman` (verified: podman 5.8.3). So
# a bare `gvproxy` lookup fails on a clean host even though gvproxy is
# installed. Resolve it without requiring the user to symlink it onto
# PATH, in priority order:
#
#   1. PATH            -- honour an explicit user-provided gvproxy.
#   2. brew --prefix podman + /libexec/podman/gvproxy
#                      -- the canonical Homebrew location (handles both
#                         arm64 /opt/homebrew and intel /usr/local).
#   3. Known libexec paths -- arm64 then intel, in case `brew` itself is
#                         not on PATH but the formula is installed.
#
# `podman info` does NOT expose the gvproxy helper path (and fails
# outright when no machine is started), so it is not a usable source.
#
# Prints the resolved absolute path on stdout and returns 0 on success;
# prints nothing and returns 1 when gvproxy cannot be found anywhere.
claude_vm_resolve_gvproxy() {
  # 1. Honour an explicit on-PATH gvproxy first.
  local p
  if p="$(command -v gvproxy 2>/dev/null)"; then
    printf '%s\n' "$p"
    return 0
  fi

  # 2. Homebrew formula libexec, located via `brew --prefix podman`.
  local prefix candidate
  if command -v brew >/dev/null 2>&1; then
    if prefix="$(brew --prefix podman 2>/dev/null)" && [ -n "$prefix" ]; then
      candidate="$prefix/libexec/podman/gvproxy"
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  # 3. Known Homebrew libexec paths (arm64 first, then intel) as a
  #    fallback when `brew` is not on PATH but podman is installed.
  for candidate in \
    /opt/homebrew/opt/podman/libexec/podman/gvproxy \
    /usr/local/opt/podman/libexec/podman/gvproxy; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

# Verify yq is present and is the v4+ mikefarah build (the eval-all /
# load API used below differs from the kislyuk Python yq).
claude_vm_require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "claude-vm: 'yq' (mikefarah v4+) is required to parse config. Install it (e.g. 'brew install yq')." >&2
    return 1
  fi
  if ! yq --version 2>/dev/null | grep -qiE 'mikefarah|version v?4'; then
    echo "claude-vm: 'yq' found but does not look like mikefarah v4+. Got: $(yq --version 2>&1)" >&2
    return 1
  fi
  return 0
}

# Portable mktemp wrapper used by every claude-vm tmpfile/tmpdir site.
#
#   claude_vm_mktemp [-d] <name-prefix>
#
# Builds the template <tmpdir>/<name-prefix>.XXXXXX, where <tmpdir> is
# $TMPDIR with any trailing slash stripped (default /tmp). The `-d` flag
# makes a directory instead of a file. The created path is printed on
# stdout; the exit status is mktemp's.
#
# Two portability hazards this centralises so no callsite re-introduces
# them:
#
#   1. NO suffix after the XXXXXX run. BSD/macOS mktemp (the only
#      supported host) substitutes the X-run ONLY when it is the final
#      component of the template. A template like `foo.XXXXXX.yml`
#      leaves the X's LITERAL, so the first run creates a fixed file
#      `foo.XXXXXX.yml` and every later run dies with "File exists".
#      GNU mktemp tolerates a trailing suffix; BSD does not. Callers
#      pass only a name-prefix and never an extension -- nothing here
#      dispatches on a filename extension (the merge/scalar helpers
#      parse contents), so the suffix was always cosmetic.
#
#   2. Trailing-slash normalisation. A $TMPDIR ending in `/` (macOS sets
#      e.g. /var/folders/.../T/) otherwise yields a doubled slash
#      (.../T//foo.XXXXXX). Harmless to mktemp but ugly in diagnostics;
#      `${tmpdir%/}` strips exactly one trailing slash for uniform paths.
claude_vm_mktemp() {
  local make_dir=0
  if [ "${1:-}" = "-d" ]; then
    make_dir=1
    shift
  fi
  local prefix="$1"
  local tmpdir="${TMPDIR:-/tmp}"
  tmpdir="${tmpdir%/}"
  if [ "$make_dir" -eq 1 ]; then
    mktemp -d "$tmpdir/$prefix.XXXXXX"
  else
    mktemp "$tmpdir/$prefix.XXXXXX"
  fi
}

# Preflight the external VM toolchain. Fails FAST with one actionable
# remediation line per missing piece, BEFORE any build/boot work starts,
# rather than dying deep in the boot sequence with an opaque error.
#
# Checks (in order):
#   - gvproxy   : resolved via claude_vm_resolve_gvproxy (not bare PATH).
#   - vfkit     : on PATH.
#   - podman    : on PATH (the default provisioner needs it).
#   - podman machine: initialized AND running (`podman info` succeeds).
#   - tinyproxy : on PATH, ONLY when the bundled default proxy is in use.
#                 An explicit custom proxy.cmd owns its own dependencies,
#                 so skip the tinyproxy check then.
#
# Args:
#   $1 -- "default-proxy" to include the tinyproxy check, anything else
#         (or empty) to skip it.
#
# Returns 0 when every required dependency is present, 1 otherwise
# (after printing every missing-piece message, so the operator sees the
# full list in one pass instead of one-at-a-time).
claude_vm_preflight_toolchain() {
  local proxy_mode="${1:-}"
  local missing=0

  if ! claude_vm_resolve_gvproxy >/dev/null; then
    echo "claude-vm: 'gvproxy' not found. It ships with podman at" >&2
    echo "  <brew-prefix>/libexec/podman/gvproxy. Install podman ('brew install podman')." >&2
    missing=1
  fi

  if ! command -v vfkit >/dev/null 2>&1; then
    echo "claude-vm: 'vfkit' not found on PATH. Install it ('brew install vfkit')." >&2
    missing=1
  fi

  if ! command -v podman >/dev/null 2>&1; then
    echo "claude-vm: 'podman' not found on PATH. Install it ('brew install podman')." >&2
    missing=1
  elif ! podman info >/dev/null 2>&1; then
    # podman is installed but no machine is initialized/running. On macOS
    # podman needs a started Linux VM (it supplies the kernel the default
    # provisioner builds inside). Probe it; a clear message beats an
    # opaque mid-build failure.
    echo "claude-vm: podman machine is not running ('podman info' failed)." >&2
    echo "  Start it: 'podman machine init' (first time) then 'podman machine start'." >&2
    missing=1
  fi

  if [ "$proxy_mode" = "default-proxy" ] && ! command -v tinyproxy >/dev/null 2>&1; then
    echo "claude-vm: 'tinyproxy' not found on PATH (required by the bundled default proxy)." >&2
    echo "  Install it ('brew install tinyproxy'), or set proxy.cmd to your own forward proxy." >&2
    missing=1
  fi

  [ "$missing" -eq 0 ]
}

# The full set of list keys that UNION (global ++ repo, de-duplicated)
# rather than following scalar repo-wins semantics. Each entry is a yq
# path expression rooted at the document. Nested paths (e.g.
# `.claude.permissions.allow`) are supported -- the splice step (below)
# assigns back through the same path expression, so arbitrary nesting
# depth works, not just top-level keys.
CLAUDE_VM_LIST_KEYS=(
  '.egress.allow'
  '.mounts'
  '.packages'
  '.apt_sources'
  '.claude.permissions.allow'
  '.claude.permissions.ask'
  '.claude.permissions.deny'
  '.claude.marketplaces'
  '.claude.plugins.bake'
  '.claude.plugins.install_at_boot'
  '.env.copy'
  '.env.files'
)

# Merge two YAML files into one document on stdout.
#   $1 -- global config path (may be absent)
#   $2 -- repo config path   (may be absent)
#
# A missing file contributes an empty document. Scalars: repo wins.
# Lists (CLAUDE_VM_LIST_KEYS, e.g. egress.allow, mounts,
# claude.permissions.allow): union, global-first, de-duplicated. A list
# key set in NEITHER layer, and any parent map left empty as a result
# (e.g. `packages`, `claude.permissions`), is pruned from the output
# entirely -- see claude_vm_prune_empty_skeleton below -- so the merged
# document never conflates "user configured this as empty" with "user
# didn't touch this at all".
#
# Implementation note: yq's `*` deep-merge clobbers arrays (repo array
# replaces global array), which is the WRONG semantics for our lists.
# So we deep-merge for scalars (step 1), explicitly recompute each list
# key as a union (step 2) and splice it back in (step 3), then prune
# the resulting empty skeleton (step 4).
claude_vm_merge_config() {
  local global="$1" repo="$2"
  local g r empty
  # Normalise missing files to an empty-document file so eval-all always
  # has exactly two parseable inputs in a known order (global first,
  # repo second). A bare /dev/null yields NO document, which makes
  # `select(fileIndex == N)` empty and collapses the whole merge -- so
  # we point missing layers at a real `{}` document instead.
  empty="$(claude_vm_mktemp claude-vm-empty)"
  printf '{}\n' > "$empty"
  if [ -n "$global" ] && [ -f "$global" ]; then g="$global"; else g="$empty"; fi
  if [ -n "$repo" ] && [ -f "$repo" ]; then r="$repo"; else r="$empty"; fi

  # Step 1: scalar layer via deep merge (second doc wins on scalars).
  # Arrays from the repo doc temporarily clobber global arrays here;
  # fixed in step 2.
  local scalars rc=0
  scalars="$(
    yq eval-all '
      select(fileIndex == 0) * select(fileIndex == 1)
    ' "$g" "$r" 2>/dev/null
  )" || { echo "claude-vm: failed to merge config (scalar layer)" >&2; rm -f "$empty"; return 1; }

  # Step 2: recompute list unions for every key in CLAUDE_VM_LIST_KEYS.
  # For each list key, concatenate global ++ repo then unique. Mapping
  # entries (e.g. `mounts`, `claude.marketplaces`) de-dupe structurally
  # under `unique`, which is the intended "identical entry collapses"
  # behavior.
  local key merged_lists=()
  for key in "${CLAUDE_VM_LIST_KEYS[@]}"; do
    local list_yaml
    list_yaml="$(
      yq eval-all "
        [select(fileIndex == 0) | ${key} // [] | .[]]
          + [select(fileIndex == 1) | ${key} // [] | .[]]
        | unique
      " "$g" "$r" 2>/dev/null
    )" || { echo "claude-vm: failed to merge $key" >&2; rm -f "$empty"; return 1; }
    merged_lists+=("$key" "$list_yaml")
  done

  # The empty-document scratch file is no longer needed past this point.
  rm -f "$empty"

  # Step 3: splice the recomputed unions back over the scalar merge, one
  # key at a time. Each list's YAML is passed in as an env-injected
  # string via strenv + from_yaml, keyed by array index so arbitrarily
  # many list keys can be spliced without colliding env var names.
  local current="$scalars" i=0 n="${#merged_lists[@]}"
  while [ "$i" -lt "$n" ]; do
    key="${merged_lists[$i]}"
    list_yaml="${merged_lists[$((i + 1))]}"
    current="$(
      CLAUDE_VM_SPLICE_YAML="$list_yaml" \
        yq eval "
          ${key} = (strenv(CLAUDE_VM_SPLICE_YAML) | from_yaml)
        " <(printf '%s\n' "$current") 2>/dev/null
    )" || { echo "claude-vm: failed to splice merged list $key" >&2; rc=1; break; }
    i=$((i + 2))
  done

  # Step 4: prune the empty skeleton (see claude_vm_prune_empty_skeleton).
  if [ "$rc" -eq 0 ]; then
    current="$(claude_vm_prune_empty_skeleton "$current")" \
      || { echo "claude-vm: failed to prune empty config skeleton" >&2; rc=1; }
  fi

  printf '%s\n' "$current"
  return "$rc"
}

# Prune the "empty skeleton" that Step 2/3 above otherwise leaves behind:
# a list key the user set in NEITHER layer still round-trips through the
# union-then-splice as an empty list (`[]`), and its parent map(s) (e.g.
# `packages`, `claude.permissions`) survive purely to hold that empty
# list. Left in place, this invites a consumer to test "did the user
# configure this?" by key PRESENCE (`has("packages")` -- wrong, always
# true) instead of entry COUNT (right) -- conflating "absent" with
# "configured empty".
#
#   $1 -- the merged YAML document (as a string, on stdin via a herestring
#         below), AFTER the list-union splice in Step 3.
#
# Two passes:
#   1. For every key in CLAUDE_VM_LIST_KEYS, delete it from the document
#      IFF its merged value is an empty list. A key with entries is left
#      untouched, so egress.allow/mounts and every populated new list
#      key round-trip exactly as before -- this only removes lists that
#      resolved to nothing.
#   2. Recursively delete any map that is now empty as a RESULT of pass 1
#      (e.g. `packages: {}` once every packages.* list was pruned and no
#      packages.* scalar was set). Applied twice: pass 1 can empty a
#      leaf map (e.g. `claude.plugins`) whose own parent (`claude`) only
#      becomes empty once that leaf is gone, so one application of the
#      empty-map delete is not enough to reach a fixpoint at this
#      schema's max nesting depth (two levels below the document root).
#      A scalar-bearing map (e.g. `packages: {update_at_boot: false}`)
#      is never empty and is therefore never touched.
claude_vm_prune_empty_skeleton() {
  local doc="$1" expr key
  expr=""
  for key in "${CLAUDE_VM_LIST_KEYS[@]}"; do
    expr="${expr}del(${key} | select(length == 0)) | "
  done
  expr="${expr}del(.. | select(tag == \"!!map\" and length == 0)) | del(.. | select(tag == \"!!map\" and length == 0))"
  yq eval "$expr" <(printf '%s\n' "$doc") 2>/dev/null
}

# ---------------------------------------------------------------------
# Four-file config: bake/boot split, ONE schema per file type (issue #179).
#
# claude-vm's config is FOUR files, all optional:
#   global bake: ~/.config/claude-vm/config-bake.yml
#   global boot: ~/.config/claude-vm/config-boot.yml
#   repo   bake: <repo>/.claude-vm/config-bake.yml
#   repo   boot: <repo>/.claude-vm/config-boot.yml
#
# Placement rule: a key that changes BYTES in the .raw image lives in a BAKE
# file; a key that changes launcher/VM wiring at run time lives in a BOOT file.
# The CONTAINING FILE carries the bake/boot semantics: a bake file's top-level
# `packages:` is the flat list of package names BAKED into the image; a boot
# file's top-level `packages:` is the flat list installed AT BOOT.
# `apt_sources:` is allowed in BOTH file types. image.root_headroom_mb is a
# BAKE key; egress / update_at_boot / add_apt_uris_to_allowlist / mounts /
# proxy / cpus / mem / claude.* / github.* are BOOT keys.
#
# Each file type has exactly ONE schema -- the one its example file documents
# (config-bake.example.yml / config-boot.example.yml) -- and readers read
# exactly that schema. Merging happens WITHIN a tier, never across tiers:
#
#   MERGED_BAKE = merge(global bake, repo bake)   -- bake-schema document
#   MERGED_BOOT = merge(global boot, repo boot)   -- boot-schema document
#
# both via claude_vm_merge_config (scalars: repo wins; lists: union). Bake
# consumers (build-content canonicalization, root_headroom) read bake-schema
# paths from MERGED_BAKE; boot consumers (cpus/mem/proxy/egress/mounts/
# claude.*/update_at_boot/boot packages) read boot-schema paths from
# MERGED_BOOT. The two `packages:` meanings never collide because they never
# share a document, and there is NO translation layer between the file schema
# and what readers consume -- a key set per the documented schema is read at
# exactly that path. (An earlier shape normalized all four files into the old
# single-file internal schema; the translation silently dropped top-level boot
# keys like `update_at_boot`, which parsed fine and were never read. One
# schema per file type makes that failure mode unrepresentable.)

# Abort (non-zero + a claude-vm: diagnostic) when the SAME apt_sources name
# appears with DIFFERING {repo, key_url} content anywhere across the two tier
# documents -- a silent-shadowing hazard the design forbids. Byte-identical
# duplicates were already collapsed by each tier merge's structural `unique`
# (and an identical entry present in both tiers is fine); any name whose
# entries are not all identical has conflicting content.
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
claude_vm_check_apt_sources_conflicts() {
  local bake_doc="$1" boot_doc="$2" dup
  # Collect .apt_sources entries from BOTH tier documents, group by name; a
  # name whose de-duplicated entry list is longer than 1 has conflicting
  # content under one name.
  dup="$(yq eval-all '
    ([select(fileIndex == 0) | .apt_sources // [] | .[]]
      + [select(fileIndex == 1) | .apt_sources // [] | .[]]) as $srcs
    | ($srcs | map(.name) | unique)
    | map(. as $n | {"name": $n, "n": [$srcs[] | select(.name == $n)] | unique | length})
    | map(select(.n > 1))
    | .[].name
  ' "$bake_doc" "$boot_doc" 2>/dev/null)"
  if [ -n "$dup" ]; then
    echo "claude-vm: apt_sources name conflict -- the following name(s) appear more than once with DIFFERING repo/key_url content across your bake/boot config files:" >&2
    printf '%s\n' "$dup" | while IFS= read -r n; do
      [ -n "$n" ] && echo "claude-vm:   - $n" >&2
    done
    echo "claude-vm: give each apt_sources entry a unique name, or make the conflicting entries identical. Refusing to silently shadow one with the other." >&2
    return 1
  fi
  return 0
}

# Emit the set of apt_source NAMES declared in the merged BAKE document, one
# per line, de-duplicated. These names are already rendered INTO the guest
# image at build time, so the boot-time apt_source render skips them (design
# point 5: "the boot render skips names already baked"). A missing/empty doc
# contributes nothing.
#   $1 -- merged BAKE document file path
claude_vm_baked_apt_source_names() {
  local bake_doc="$1"
  [ -n "$bake_doc" ] && [ -f "$bake_doc" ] || return 0
  yq eval '.apt_sources // [] | .[] | .name // ""' "$bake_doc" 2>/dev/null \
    | grep -v '^$' | sort -u
}

# Emit the BOOT-tier apt_sources TSV: the BOOT document's apt_sources MINUS
# any name that is already baked into the image (per
# claude_vm_baked_apt_source_names). The boot launcher renders these into the
# guest's LIVE /etc/apt so an install_at_boot can pull from a third-party repo
# declared in a BOOT file -- but a baked apt_source is already present in the
# image, so re-rendering it at boot is skipped. Output shape is identical to
# claude_vm_apt_sources (name<TAB>repo<TAB>key_url).
#   $1 -- merged BOOT document file path
#   $2 -- merged BAKE document file path
claude_vm_boot_apt_sources() {
  local boot_doc="$1" bake_doc="$2"
  local baked_names
  baked_names="$(claude_vm_baked_apt_source_names "$bake_doc")"
  # Fast path: nothing baked -> every boot-declared apt_source is a boot render.
  if [ -z "$baked_names" ]; then
    claude_vm_apt_sources "$boot_doc"
    return 0
  fi
  # Filter out rows whose first TSV field (the name) is in the baked set,
  # preserving each surviving row's bytes VERBATIM (including a trailing empty
  # key_url field). awk keys on $1 against the baked-name set so a partial-name
  # collision never mis-matches; the whole line is emitted unchanged on a miss.
  claude_vm_apt_sources "$boot_doc" | awk -F'\t' -v baked="$baked_names" '
    BEGIN { n = split(baked, arr, "\n"); for (i = 1; i <= n; i++) if (arr[i] != "") skip[arr[i]] = 1 }
    { if (!($1 in skip)) print }
  '
}

# Read a scalar from a merged-config document (on stdin or in a file),
# applying a hardcoded fallback when the key is absent/null.
#   $1 -- merged config file path
#   $2 -- yq path expression (e.g. '.cpus', '.repo.mount')
#   $3 -- fallback value if the key is null/absent
#
# NOT boolean-safe: the `// ""` idiom below treats an explicit YAML
# `false` the same as an absent key (both stringify to empty via `// ""`,
# so this falls through to $fallback). That is correct for the existing
# string/number scalars (cpus, mem, repo.mount, proxy.*, etc. -- none of
# which are booleans), but WRONG for a boolean key where `false` is a
# meaningful, distinct-from-absent value. Use claude_vm_bool_scalar for
# those (update_at_boot, claude.plugins.update_at_boot).
claude_vm_scalar() {
  local file="$1" path="$2" fallback="$3" val
  val="$(yq eval "$path // \"\"" "$file" 2>/dev/null)"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '%s\n' "$fallback"
  else
    printf '%s\n' "$val"
  fi
}

# Read a BOOLEAN scalar from a merged-config document, applying a
# hardcoded fallback ONLY when the key is genuinely absent/null --
# unlike claude_vm_scalar, an explicit `false` is preserved and
# returned as "false", not silently replaced by $fallback.
#   $1 -- merged config file path
#   $2 -- yq path expression (e.g. '.update_at_boot')
#   $3 -- fallback value if the key is null/absent (e.g. "true"/"false")
#
# Presence check: `(<path> == null)` is true both when the key is absent
# AND when it is explicitly set to YAML `null`; either way there is no
# value to preserve, so the fallback applies. We branch explicitly on
# that presence check rather than yq's `//` operator, because `//`
# treats the boolean `false` itself as falsy and would substitute
# $fallback for it too -- exactly the bug this accessor exists to avoid.
claude_vm_bool_scalar() {
  local file="$1" path="$2" fallback="$3" is_null
  is_null="$(yq eval "(${path} == null)" "$file" 2>/dev/null)"
  if [ "$is_null" != "false" ]; then
    printf '%s\n' "$fallback"
  else
    yq eval "${path}" "$file" 2>/dev/null
  fi
}

# Emit the egress allowlist, one host per line, from a merged-config file.
claude_vm_egress_hosts() {
  local file="$1"
  yq eval '.egress.allow // [] | .[]' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------
# TSV RECORDS: emit with yq @tsv, split BY HAND (issue #226).
#
# Several helpers below move multi-field records around as yq `@tsv` lines. No
# reader of one may take it apart with `IFS=$'\t' read -r a b`. A tab is IFS
# WHITESPACE, so `read` collapses a RUN of tabs into ONE separator and also
# strips a LEADING one: a record whose first field is empty loses it and every
# later field shifts left, and one whose middle field is empty loses that. Both
# are silent -- the reader gets a wrong-but-plausible value, never an error.
#
# Every reader therefore takes the whole line with `IFS= read -r` and splits it
# with `${rec%%$TAB*}` / `${rec#*$TAB}` parameter expansions, which do not care
# whether a field is empty. Those expansions are TOTAL because `@tsv` over a
# fixed-length array always writes every separator (an N-element array yields
# N-1 tabs) and escapes any tab or newline inside a value, so a record can
# neither lose a separator nor grow a stray one.
#
# Splitting correctly makes an empty key field VISIBLE rather than harmless;
# it does not make such an entry usable. Rejecting one is the other half, and
# it happens at config load: claude_vm_check_mounts (below),
# claude_vm_check_marketplace_names, and the empty-ref branch inside
# claude_vm_render_guest_settings. payload/README.md -> *Splitting a TSV record
# back apart* carries the full write-up.
# ---------------------------------------------------------------------

# Emit mounts as tab-separated "source<TAB>tag<TAB>path" lines from a
# merged-config file. `path` (issue #157, the guest mountpoint override) is
# emitted EMPTY when unset, and the effective mountpoint is then derived by
# claude_vm_mount_guest_path below rather than defaulted here -- the default
# depends on the entry's own tag, which a yq default expression cannot see.
#
# Every field is guarded with `// ""` for the same reason every other @tsv
# emitter in this file is: an UNGUARDED `.tag` renders an OMITTED key as the
# literal four-character string `null`, which vfkit would then take as the mount
# tag. With the guard, an omitted key and an explicit `tag: ""` both reach the
# reader as a genuinely empty field, so one check (claude_vm_check_mounts)
# covers both spellings.
#
# THREE fields: `tag` is an optional MIDDLE one -- exactly the shape the
# collapsing `IFS=$'\t' read` destroys, since an entry with no tag emits
# `source<TAB><TAB>path` and the collapse would hand the PATH to the tag slot.
# Every reader splits by hand; see the TSV RECORDS block above. (The record
# carried a fourth field, `mode`, until read-only support was removed -- see the
# extra-mount block near the top of this file and issue #233.)
claude_vm_mount_specs() {
  local file="$1"
  yq eval '
    .mounts // [] | .[]
    | [(.source // ""), (.tag // ""), (.path // "")] | @tsv
  ' "$file" 2>/dev/null
}

# Emit "entry-number<TAB>source" for every `mounts` entry that CARRIES a `mode:`
# key, from a merged-config file. Feeds claude_vm_check_mounts's abort on a key
# this stack cannot honour (see the extra-mount block near the top of this file).
#
# It is a separate emitter rather than another field on claude_vm_mount_specs
# because it asks a different question -- is the key PRESENT? -- which no value
# can answer: `mode: ""`, `mode:` (a null) and an omitted `mode:` all render as
# the same empty field, and the first two are supplied while the third is not.
# `has("mode")` distinguishes them (verified against yq v4.53.3 over all three
# spellings plus a `- {}` entry, which does not error). Keeping it separate also
# means the whole deprecation gate is one function and one call to delete when
# #233 lands its own surface, rather than a field every mounts reader carries.
#
# The entry number is `to_entries`' index + 1, so it counts through the MERGED
# list exactly the way claude_vm_check_mounts's own idx does.
#
# This is asked of a MERGED document, unlike claude_vm_env_bake_has_key, and
# claude_vm_prune_empty_skeleton reaches it in ONE spelling. Its first pass
# deletes only a whole CLAUDE_VM_LIST_KEYS entry that resolved to an empty list,
# so it never touches a key inside a list ELEMENT. Its empty-map pass is
# `del(.. | select(tag == "!!map" and length == 0))`, and that `..` DOES descend
# into list elements: the entry map itself is never empty (`{mode: null}` has
# length 1), but a `mode: {}` written inside it is, and is deleted. Measured
# through the real claude_vm_merge_config against yq v4.53.3, in both layers:
# `mode: ro`, `mode: ""`, `mode: []` and a valueless `mode:` all survive the
# merge and abort the launch, while `mode: {}` arrives here as an absent key and
# the launch proceeds. config-test.sh drives the surviving spellings through the
# real merge -- so a key added to CLAUDE_VM_LIST_KEYS cannot quietly change
# them -- but carries no `{}` case, which is why the gap was invisible.
claude_vm_mount_mode_entries() {
  local file="$1"
  yq eval '
    .mounts // [] | to_entries | .[]
    | select(.value | has("mode"))
    | [(.key + 1), (.value.source // "")] | @tsv
  ' "$file" 2>/dev/null
}

# Expand a leading `~` in a mount source to $HOME. The config is YAML, not
# shell, so nothing expands it for us. Shared by the launcher's extra-mount
# loop and by claude_vm_check_mounts's host-existence check, so the path the
# check stats is byte-identical to the one the launcher shares (issue #157 --
# before the existence check there were two copies of this expansion and only
# the launcher's ran).
#   $1 -- the configured source path
claude_vm_expand_mount_source() {
  local src="$1"
  case "$src" in
    "~"/*) printf '%s\n' "$HOME/${src#"~/"}" ;;
    "~")   printf '%s\n' "$HOME" ;;
    *)     printf '%s\n' "$src" ;;
  esac
}

# The guest mountpoint for one mount entry: its `path:` when set, else
# <CLAUDE_VM_GUEST_MOUNT_ROOT>/<tag>. One definition, read by the validator and
# by the launcher's manifest write, so the path the validator judges and the
# path the guest mounts at are the same string by construction.
#
# The result is NORMALIZED, and that normalization is a SECURITY boundary
# rather than cosmetics: every guard in claude_vm_check_mounts
# (claude_vm_guest_path_covers, claude_vm_guest_paths_overlap,
# claude_vm_guest_system_path_containing, the duplicate-mountpoint test) is a
# STRING relation over this function's output, so any spelling that reaches
# them un-normalized walks past all of them at once while naming a guest
# directory they would have rejected. The launcher writes this same output to
# mounts.tsv, so the string the guest mounts at is the string the guards judged.
#
# The class is "two different strings that name one guest path". Each member is
# either resolvable HOST-side (normalize it) or not (reject it in the
# validator):
#
#   - repeated slashes (`//mnt/repo`): resolvable, collapsed below. Linux
#     treats a run of slashes as one separator.
#   - a trailing slash (`/mnt/repo/`): resolvable, dropped below.
#   - a `.` segment, leading/interior/trailing (`/./etc`, `/mnt/./repo`,
#     `/etc/.`, and `/.` for the guest root itself): resolvable, collapsed
#     below. `.` names the directory it sits in whatever the guest's filesystem
#     looks like -- unlike `..` it cannot change meaning through a symlink --
#     so the host can drop it without guessing. A run of THREE or more dots
#     (`...`) is an ordinary directory name and is deliberately left alone;
#     the two-dot run is the next bullet, left alone here so the validator
#     can reject it.
#   - a `..` segment: NOT resolvable (it needs the guest's filesystem, and a
#     symlink mid-path changes where it lands), so claude_vm_check_mounts
#     rejects such a path outright rather than guessing.
#   - a RELATIVE path: rejected by claude_vm_check_mounts -- its meaning
#     depends on the boot launcher's cwd, which is not a host-side fact.
#   - a GUEST SYMLINK: not resolvable host-side at ALL and not visible in the
#     string, so no normalizer can catch it. The guest base is usr-merged --
#     measured on debian:bookworm/arm64, /bin -> usr/bin, /sbin -> usr/sbin and
#     /lib -> usr/lib are symlinks (the /lib{32,64,x32} spellings are absent on
#     that arch) -- so `path: /bin` and `path: /usr/bin` name one directory.
#     BOTH names of each pair are COVERED by CLAUDE_VM_GUEST_SYSTEM_PATHS
#     above: /bin, /sbin and /lib are in the list themselves, and their
#     /usr/... targets sit under /usr, which is. So the guards reject either
#     spelling; for anything the denylist does not cover, the guest's own
#     occupancy check (build-guest-image.sh's boot_mount_phase) is the
#     backstop.
#
# Case folding is not in the class: the guest root filesystem is ext4, so
# `/Etc` and `/etc` are genuinely different directories.
#   $1 -- the entry's tag
#   $2 -- the entry's configured path (may be empty)
claude_vm_mount_guest_path() {
  local tag="$1" path="$2" prev=""
  # The `/`, `//` and `/./` literals below are held in VARIABLES rather than
  # written inline, because a backslash-escaped slash in the REPLACEMENT half of
  # `${var//pattern/replacement}` is version-dependent: bash >= 4.3 unescapes
  # `\/` to `/`, while bash 3.2 (the /bin/bash macOS still ships) leaves the
  # backslash in. Measured on both, running THIS function with its literals
  # written inline as `${path//\/\//\/}`: bash 3.2 returns `/mnt/repo\` for
  # `/mnt/repo/`, `\\/mnt\/repo` for `///mnt//repo` and `\/etc` for `/./etc`,
  # where bash 5.3 returns `/mnt/repo`, `/mnt/repo` and `/etc`. That silently
  # defeats the whole normalization and with it every guard downstream, and it
  # is pinned by the old-bash block in test/config-test.sh. A variable expands
  # to a plain `/` with no escape to interpret, so both shells agree. (Nothing
  # in this file needs bash 4 any more. It once did -- `local -A` in
  # claude_vm_render_guest_settings -- excused as failing LOUDLY and much later
  # in the launch; issue #108's real launch showed the excuse was wrong on both
  # counts, so the render was rewritten for 3.2 too. A guard would still have to
  # survive 3.2 either way: it must not fail open on the way to someone else's
  # error.)
  local sl=/ dbl=// dotseg=/./
  [ -n "$path" ] || path="$CLAUDE_VM_GUEST_MOUNT_ROOT/$tag"
  # Append one trailing slash so a FINAL `.` segment is spelled `/./` like an
  # interior one and the single collapse below reaches it too (`/etc/.` ->
  # `/etc/./`). The strip loop then takes this slash back off along with any
  # the operator wrote.
  path="$path$sl"
  # Collapse `//` and `/./` to a fixpoint: one pass over `///` leaves `//`, and
  # one over `/././` leaves `/./`, because each substitution consumes
  # non-overlapping matches. Collapsing `/./` can never CREATE a `..` -- the
  # replacement leaves a `/` between the characters that surrounded the match,
  # so two dots can only become adjacent if they already were.
  while [ "$path" != "$prev" ]; do
    prev="$path"
    path="${path//$dbl/$sl}"
    path="${path//$dotseg/$sl}"
  done
  # Drop trailing slashes, but never reduce `/` itself to the empty string.
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done
  printf '%s\n' "$path"
}

# Does NORMALIZED absolute guest path $1 COVER $2 -- is it equal to it, or a
# proper ancestor of it? Returns 0 when it does. The directed half of the
# overlap relation below, and a guard in its own right: a mount at a path that
# covers something hides that something, while a mount at a path merely INSIDE
# something is a different (and for a single file, permitted) shape.
#
# The test appends a `/` to each side so a prefix match can only land on a
# component boundary: `/mnt/repo/` prefixes `/mnt/repo/sub/` but not
# `/mnt/repofoo/`. `/` is already its own separator and is left alone, which is
# what makes the guest root an ancestor of everything.
#   $1, $2 -- normalized absolute guest paths (claude_vm_mount_guest_path
#             output, or a reserved/system mountpoint constant)
claude_vm_guest_path_covers() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 0
  [ "$a" = "/" ] || a="$a/"
  [ "$b" = "/" ] || b="$b/"
  case "$b" in "$a"*) return 0 ;; esac
  return 1
}

# Do two NORMALIZED absolute guest paths name overlapping mount territory --
# equal, or one a proper ancestor of the other? Returns 0 when they overlap.
# Symmetric, and defined as covers-either-way so the component-boundary logic
# lives in exactly one place.
#
# Mount collisions are not a string-equality relation, which is what the
# reserved-mountpoint guard originally tested. A path ABOVE a reserved
# mountpoint swallows it (`path: /mnt` covers every built-in share at once,
# `path: /` covers the guest root), and a path BELOW one lands INSIDE somebody
# else's share (`path: /mnt/repo/sub` makes the guest mkdir a directory in the
# host's shared repo tree, then hides whatever the repo really has there).
# Equal, above and below are the ways two mountpoints interfere, so the guard
# tests the relation rather than the string.
#   $1, $2 -- normalized absolute guest paths
claude_vm_guest_paths_overlap() {
  claude_vm_guest_path_covers "$1" "$2" && return 0
  claude_vm_guest_path_covers "$2" "$1" && return 0
  return 1
}

# Which guest SYSTEM path does a normalized mountpoint sit inside, if any?
# Prints that system path and returns 0; prints nothing and returns 1 when the
# mountpoint is not under one. "Inside" is strict: a mountpoint EQUAL to a
# system path is not inside it, it IS it, and that is the covers case above.
#
# Used only by the single-FILE rule, which needs to know not merely THAT the
# target is under a system path but WHICH one -- /root/.gitconfig is the
# sanctioned shape, /etc/ld.so.preload is a mount over a system file.
#   $1 -- normalized absolute guest mountpoint
claude_vm_guest_system_path_containing() {
  local gpath="$1" sp
  for sp in $CLAUDE_VM_GUEST_SYSTEM_PATHS; do
    [ "$gpath" = "$sp" ] && continue
    if claude_vm_guest_path_covers "$sp" "$gpath"; then
      printf '%s\n' "$sp"
      return 0
    fi
  done
  return 1
}

# Abort (non-zero + a claude-vm: diagnostic) when a `mounts` entry cannot
# produce a usable mount. Hard abort, never warn-and-limp: every case below
# ends with the operator not getting the mount they asked for, and a VM that
# boots without it looks like a working VM.
#
# The original pair (issue #226) is unusable-share territory -- no `source`
# (no host path to share) or no `tag` (nothing for the guest to mount it by).
# Both an omitted key and an explicit empty string count, since
# claude_vm_mount_specs normalizes them to the same empty field. A tagless entry
# used to reach vfkit as `mountTag=` (or, before the `// ""` guard above, as
# `mountTag=null`), and two such entries would collide on that one tag; a
# sourceless entry was silently dropped by the launcher's extra-mount loop.
#
# Issue #157 extends the same function -- rather than adding a second gate the
# launcher would have to remember to call -- with the cases the guest-side mount
# step makes reachable:
#
#   - a tag outside [A-Za-z0-9._-]: the tag travels inside vfkit's
#     comma-delimited `--device virtio-fs,sharedDir=...,mountTag=<tag>` string
#     and again as a `mount -t virtiofs -o rw <tag> <path>` argument in the
#     guest, so a comma or whitespace in it corrupts one or both. Same
#     charset the marketplace-name and apt_source-name guards use.
#   - a tag that the charset admits but one of its OTHER uses does not. The tag
#     is also a bare PATH COMPONENT (in three trees) and a bare ARGV WORD, so
#     `.` and `..` walk up out of every tree that embeds it and a leading `-`
#     is read as an option by the guest's `mount`. payload/README.md -> *The tag
#     is not just a tag* enumerates the uses these two arms are derived from.
#   - a DIRECTORY `source` whose path contains a comma: the source is what
#     vfkit shares, so it sits inside that same comma-delimited device string,
#     as the only field of it with no charset check of its own. A single-FILE
#     source is exempt -- what gets shared then is the wrap directory, whose
#     <tag> component is already checked and whose PARENT ($RUN/mount-wrap, or
#     a $TMPDIR mktemp) is not a config value at all: the launcher checks that
#     one where it wraps the file. See the arm itself for the full reasoning.
#   - a tag colliding with a RESERVED built-in tag: the launcher always attaches
#     repo/runconfig/claudebin/claudecreds and the image's fstab always mounts
#     them, so a second device under one of those names puts the operator's own
#     directory where the repo, the run config, the verified binary or the OAuth
#     credential is supposed to be.
#   - a DUPLICATE tag across the merged global+repo list: two vfkit devices
#     under one tag, and one guest mount that resolves to whichever the kernel
#     enumerated first. Nondeterministic, so one of the two mounts is simply
#     the wrong directory.
#   - a `source` that does not exist on the host: vfkit fails to start (or
#     shares an empty dir) minutes into a launch, with a message about a device
#     rather than about the config line that caused it.
#   - a `path` that is not absolute: it becomes the guest `mount` target, which
#     would resolve against the boot launcher's cwd rather than where the
#     operator meant.
#   - a `path` overlapping a reserved guest mountpoint -- landing ON one,
#     ABOVE one, or INSIDE one. All three are the same defect: `/mnt/repo`
#     replaces the working tree, `/mnt` (or `/`) swallows every built-in share
#     at once, and `/mnt/repo/sub` makes the guest create a directory inside
#     the host's shared repo tree and hides whatever the repo has there.
#   - a `path` shadowing a guest SYSTEM path (CLAUDE_VM_GUEST_SYSTEM_PATHS).
#     Linux stacks a mount, so whatever was at that path becomes unreachable
#     for the life of the VM, and the mount phase runs first -- `path: /root`
#     hides HOME before the credential seed writes /root/.claude into it. The
#     rule differs by SHAPE, because a directory mount hides a whole subtree
#     while a single-file bind replaces exactly one file:
#       * a DIRECTORY source may not land on, above, or inside a system path;
#       * a single-FILE source may not land on or above one, and may sit
#         INSIDE only /root, /home or /tmp (CLAUDE_VM_GUEST_USER_FILE_PATHS),
#         whose contents are user data. Inside any other system path every
#         file belongs to a package, so the bind would replace a system file.
#     That split is what keeps this issue's own `path: /root/.gitconfig` case
#     working while `path: /root` and `path: /etc/ld.so.preload` do not.
#   - a `path` colliding with another entry's effective mountpoint: the later
#     mount shadows the earlier one, so one configured mount is silently
#     unreachable.
#
# A `mode:` key on ANY entry is also an abort, checked before the loop over its
# own emitter (claude_vm_mount_mode_entries). It is not a malformed value but a
# key this stack cannot honour at all: see the extra-mount block near the top of
# this file for why read-only is unenforceable here, and issue #233 for the
# design that will enforce it. Ignoring the key would leave the operator
# believing a share is read-only when the guest can write it.
#
#   $1 -- merged BOOT document file path (mounts is a BOOT key)
claude_vm_check_mounts() {
  local boot_doc="$1" mnt_tab record src rest tag path gpath expanded
  local idx=0 bad=0 seen_tags=" " reserved_tags=" " rtag rpath spath dup
  local mode_idx mode_src sp container
  local -a reserved_paths=()
  local -a seen_paths=()
  [ -n "$boot_doc" ] && [ -f "$boot_doc" ] || return 0
  mnt_tab=$'\t'
  # Space-padded sets for the TAG membership tests below, and ARRAYS for both
  # sets of PATHS. A space-padded set is only sound when the value's charset
  # EXCLUDES the delimiter, and that is true of tags and false of paths: a tag
  # is charset-validated to [A-Za-z0-9._-] below, while a `path:` is validated
  # only for absolute-ness and `..`. On a padded string, `path: /opt/a b`
  # followed by `path: /opt/a` reads as a repeat and aborts a pair of perfectly
  # distinct mountpoints, so the seen set is an array compared with `=`. (The
  # tag charset check reports and continues rather than skipping the rest of
  # the entry, so a tag carrying a space does still reach the padded set --
  # but that config is ALREADY aborting on the charset line that names the real
  # defect, so the extra line is detail on a rejected config, never a false
  # rejection of a good one.) The reserved set has a second reason to be an
  # array: it is tested by a relation between two paths rather than by
  # membership. The reserved PATHS are derived from the reserved TAGS so the
  # two can never drift apart: the built-in shares are mounted at <root>/<tag>
  # by the image's own fstab. The guest wrap mountpoint joins them -- it is not
  # tag-derived, since the boot launcher creates it rather than the fstab.
  for rtag in $CLAUDE_VM_RESERVED_MOUNT_TAGS; do
    reserved_tags="${reserved_tags}${rtag} "
    reserved_paths+=("$(claude_vm_mount_guest_path "$rtag" "")")
  done
  reserved_paths+=("$CLAUDE_VM_GUEST_WRAP_MOUNT")
  # The `mode:` abort, over its own emitter. Same empty-line skip and hand split
  # as the main loop -- an empty result set is one empty LINE here too.
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    mode_idx=${record%%$mnt_tab*}
    mode_src=${record#*$mnt_tab}
    echo "claude-vm: mounts entry #${mode_idx} ('$mode_src') sets 'mode:'. claude-vm no longer has that key:" >&2
    echo "claude-vm:   every extra mount is READ-WRITE, and read-only cannot be enforced on this stack --" >&2
    echo "claude-vm:   vfkit's virtio-fs device has no read-only option, and the guest session is root, so" >&2
    echo "claude-vm:   a guest-side 'ro' is undoable from inside the guest it would be restraining." >&2
    echo "claude-vm:   Enforced read-only is tracked as issue #233. Remove the 'mode:' line -- claude-vm" >&2
    echo "claude-vm:   aborts rather than ignoring it, so you never believe a share is read-only when it" >&2
    echo "claude-vm:   is not. Do not point a mount at anything you would mind the guest rewriting." >&2
    bad=1
  done < <(claude_vm_mount_mode_entries "$boot_doc")
  while IFS= read -r record; do
    # An EMPTY result set is one empty line, not zero bytes: yq prints a
    # newline for `.mounts // [] | .[]` when there are no mounts at all.
    # Skip that, and do not let it consume an entry number. A real entry --
    # even `- {}` -- always carries its separators and so is never empty.
    [ -n "$record" ] || continue
    idx=$((idx + 1))
    src=${record%%$mnt_tab*}
    rest=${record#*$mnt_tab}
    tag=${rest%%$mnt_tab*}
    path=${rest#*$mnt_tab}
    if [ -z "$src" ]; then
      echo "claude-vm: mounts entry #${idx} has no source -- there is no host path to share." >&2
      bad=1
      continue
    fi
    if [ -z "$tag" ]; then
      echo "claude-vm: mounts entry #${idx} ('$src') has no tag -- the guest mounts each share BY its tag," >&2
      echo "claude-vm:   so an entry without one can never be mounted, and two of them would collide." >&2
      echo "claude-vm:   give that entry a unique, non-empty 'tag:' in your config-boot.yml." >&2
      bad=1
      # Everything below keys off the tag (the guest mountpoint default, the
      # duplicate sets); with none there is nothing further to say about this
      # entry that would not just repeat the line above.
      continue
    fi
    case "$tag" in
      *[!A-Za-z0-9._-]*)
        echo "claude-vm: mounts entry #${idx} ('$src') has tag '$tag', which contains characters outside" >&2
        echo "claude-vm:   [A-Za-z0-9._-]. The tag travels inside vfkit's comma-delimited device string and" >&2
        echo "claude-vm:   again as a guest 'mount -t virtiofs' argument, so it must stay in that charset." >&2
        bad=1
        ;;
    esac
    # The charset is necessary and not sufficient, because the tag is not one
    # thing. Every use of it takes the string as-is -- nothing escapes or
    # rewrites it on the way -- and the arms below are the spellings that pass
    # the charset while being unusable in one of those positions. See
    # payload/README.md -> *The tag is not just a tag* for the enumeration of
    # uses these arms are derived from.
    case "$tag" in
      .|..)
        echo "claude-vm: mounts entry #${idx} ('$src') has tag '$tag', which is not a usable path COMPONENT --" >&2
        echo "claude-vm:   and the tag is used as one in the default guest mountpoint $CLAUDE_VM_GUEST_MOUNT_ROOT/<tag>," >&2
        echo "claude-vm:   in the host-side directory a single-file source is wrapped in, and in that wrap's own" >&2
        echo "claude-vm:   guest mountpoint under $CLAUDE_VM_GUEST_WRAP_MOUNT. A dot-directory name walks one level" >&2
        echo "claude-vm:   UP out of whichever of those this entry uses -- the default mountpoint, and the two wrap" >&2
        echo "claude-vm:   paths when the source is a single file -- so the share would carry a host directory you" >&2
        echo "claude-vm:   never named. Pick an ordinary name -- '...' and 'a..b' are ordinary and are accepted." >&2
        bad=1
        ;;
      -*)
        echo "claude-vm: mounts entry #${idx} ('$src') has tag '$tag', which begins with '-'. The guest" >&2
        echo "claude-vm:   mounts each share with 'mount -t virtiofs -o rw <tag> <path>', where the tag is a" >&2
        echo "claude-vm:   bare argv word, so a leading dash makes it an OPTION instead of the device." >&2
        echo "claude-vm:   Measured on util-linux 2.38.1: '-a' exits 0 having mounted nothing, which the" >&2
        echo "claude-vm:   guest would report as a successful mount, and '--bind', '-o' and '-r' fail" >&2
        echo "claude-vm:   outright. Pick a tag that does not start with '-'." >&2
        bad=1
        ;;
    esac
    case "$reserved_tags" in
      *" $tag "*)
        echo "claude-vm: mounts entry #${idx} ('$src') uses the reserved tag '$tag'. claude-vm always attaches" >&2
        echo "claude-vm:   its own shares under: $CLAUDE_VM_RESERVED_MOUNT_TAGS." >&2
        echo "claude-vm:   Reusing one would put your directory where the repo, the run config, the verified" >&2
        echo "claude-vm:   claude binary or the OAuth credential belongs. Pick a different tag." >&2
        bad=1
        ;;
    esac
    case "$seen_tags" in
      *" $tag "*)
        echo "claude-vm: mounts entry #${idx} ('$src') repeats the tag '$tag' used by an earlier entry." >&2
        echo "claude-vm:   Two shares under one tag give the guest one mount resolving to whichever device" >&2
        echo "claude-vm:   the kernel enumerated first, so one of the two directories is silently lost." >&2
        echo "claude-vm:   Note that mounts is a UNION list: an entry may come from the global config." >&2
        bad=1
        ;;
      *) seen_tags="$seen_tags$tag " ;;
    esac
    expanded="$(claude_vm_expand_mount_source "$src")"
    if [ ! -e "$expanded" ]; then
      echo "claude-vm: mounts entry #${idx} source '$src' does not exist on the host" >&2
      echo "claude-vm:   (resolved to '$expanded'). vfkit cannot share a path that is not there, so this" >&2
      echo "claude-vm:   would fail minutes into the launch with a message about a device, not about" >&2
      echo "claude-vm:   this config line. Create it, or correct the path in your config-boot.yml." >&2
      bad=1
    fi
    if [ -n "$path" ]; then
      case "$path" in
        /*) : ;;
        *)
          echo "claude-vm: mounts entry #${idx} ('$src') has path '$path', which is not absolute. The path is" >&2
          echo "claude-vm:   the guest mountpoint, so a relative one would resolve against the boot" >&2
          echo "claude-vm:   launcher's working directory rather than where you meant it." >&2
          bad=1
          ;;
      esac
      # `..` cannot be resolved host-side (it needs the guest's filesystem, and
      # a symlink in the middle changes the answer), so a path carrying one
      # cannot be compared against the reserved set below -- `/mnt/x/../repo`
      # would pass every collision check and still land on /mnt/repo. Reject
      # rather than guess. Its sibling `.` gets the OPPOSITE treatment, and is
      # not rejected here: a `.` segment resolves to the directory it sits in
      # no matter what the guest's filesystem holds, so the normalizer
      # COLLAPSES it and every check below sees the resolved string. The two
      # halves of the class, and why each is normalized or rejected, are
      # enumerated at that function.
      case "/$path/" in
        */../*)
          echo "claude-vm: mounts entry #${idx} ('$src') has path '$path', which contains a '..' segment." >&2
          echo "claude-vm:   Where that resolves depends on the guest's filesystem, so claude-vm cannot check" >&2
          echo "claude-vm:   it against its own reserved mountpoints. Write the path out in full." >&2
          bad=1
          ;;
      esac
    fi
    gpath="$(claude_vm_mount_guest_path "$tag" "$path")"
    for rpath in "${reserved_paths[@]}"; do
      claude_vm_guest_paths_overlap "$gpath" "$rpath" || continue
      echo "claude-vm: mounts entry #${idx} ('$src') would mount at '$gpath', which overlaps '$rpath' --" >&2
      echo "claude-vm:   a guest path claude-vm reserves for its own use ($CLAUDE_VM_RESERVED_MOUNT_TAGS" >&2
      echo "claude-vm:   under $CLAUDE_VM_GUEST_MOUNT_ROOT, plus $CLAUDE_VM_GUEST_WRAP_MOUNT, where a" >&2
      echo "claude-vm:   single-file mount is staged). Mounting ON a reserved path, ABOVE it or INSIDE it" >&2
      echo "claude-vm:   hides the repo, the run config, the verified claude binary or the OAuth credential" >&2
      echo "claude-vm:   from the rest of the boot -- or writes your mountpoint into the share it lands in." >&2
      bad=1
      break
    done
    # The guest OS's own directories. Split by SHAPE: the host already knows
    # which shape an entry is, because it stats the source to decide whether to
    # wrap it (`-f` is true for a regular file and false for a directory, the
    # same one-line test the launcher's extra-mount loop makes). A source that
    # is not there at all was rejected above; it falls to the DIRECTORY rule
    # here, which is the stricter of the two.
    if [ -f "$expanded" ]; then
      # SINGLE FILE: a bind replaces exactly one file, so sitting inside a
      # system path is fine where the files are the user's. Landing ON a system
      # path or ABOVE one is not -- `path: /etc` binds a file over the whole
      # directory, `path: /` over the guest root.
      for sp in $CLAUDE_VM_GUEST_SYSTEM_PATHS; do
        claude_vm_guest_path_covers "$gpath" "$sp" || continue
        echo "claude-vm: mounts entry #${idx} ('$src') would mount its single file at '$gpath', which is the" >&2
        echo "claude-vm:   guest OS path '$sp' or sits above it. A file mounted there replaces the whole" >&2
        echo "claude-vm:   directory for the life of the VM -- Linux stacks a mount rather than merging it." >&2
        echo "claude-vm:   Give the entry a 'path:' naming the FILE it should become, e.g." >&2
        echo "claude-vm:   /root/.gitconfig." >&2
        bad=1
        break
      done
      if container="$(claude_vm_guest_system_path_containing "$gpath")"; then
        case " $CLAUDE_VM_GUEST_USER_FILE_PATHS " in
          *" $container "*) : ;;
          *)
            echo "claude-vm: mounts entry #${idx} ('$src') would mount its single file at '$gpath', inside the" >&2
            echo "claude-vm:   guest OS directory '$container', where every file belongs to a system package." >&2
            echo "claude-vm:   Mounting over one replaces it for the life of the VM, and the mount phase runs" >&2
            echo "claude-vm:   before everything else in the boot, so the rest of the boot never sees the" >&2
            echo "claude-vm:   file the image shipped. A single-file mount may sit inside" >&2
            echo "claude-vm:   $CLAUDE_VM_GUEST_USER_FILE_PATHS (user data), or anywhere outside the OS tree" >&2
            echo "claude-vm:   ($CLAUDE_VM_GUEST_MOUNT_ROOT/<tag>, /srv, /opt)." >&2
            bad=1
            ;;
        esac
      fi
    else
      # A DIRECTORY source is what vfkit SHARES, so the operator's own path
      # travels inside the same comma-delimited
      # `--device virtio-fs,sharedDir=<source>,mountTag=<tag>` string the tag
      # charset check above exists to protect -- that string's other field,
      # which the tag's own check does not reach. Measured on vfkit v0.6.4: a
      # bare comma (`sharedDir=/tmp/a,b`) dies with `unknown option for
      # virtio-fs devices: b`, minutes into the launch and naming a device
      # rather than this config line, which is the same failure the
      # host-existence check above exists to forestall; and a source that
      # spells a second `sharedDir=` REPLACES the first (last key wins, also
      # measured), so the guest would get a directory this entry never named.
      # A single-FILE source is exempt and is not checked here: what gets
      # shared then is the wrap directory $MOUNT_WRAP_DIR/<tag>, whose <tag>
      # COMPONENT the tag check above already settled, so a comma in the file's
      # own path reaches nothing but a hard link and a mounts.tsv field. That
      # settles the component and not the directory: $MOUNT_WRAP_DIR is
      # $RUN/mount-wrap, or a $TMPDIR mktemp when $RUN sits inside the repo
      # share, and neither is a config value this function can see. The
      # launcher checks THAT for a comma where it wraps the file, and blames
      # $TMPDIR or the run dir rather than the entry -- an earlier, cause-
      # naming abort, since those two paths already reach vfkit through
      # argument strings nothing checks (see the comment at MOUNT_WRAP_DIR).
      case "$expanded" in
        *,*)
          echo "claude-vm: mounts entry #${idx} ('$src') shares a DIRECTORY whose path contains a ','. claude-vm" >&2
          echo "claude-vm:   names the shared directory inside vfkit's comma-delimited" >&2
          echo "claude-vm:   '--device virtio-fs,sharedDir=...,mountTag=...' string, so a comma in it is read as the" >&2
          echo "claude-vm:   start of another device option: vfkit either aborts the launch with a message about a" >&2
          echo "claude-vm:   device rather than about this config line, or shares a different directory entirely." >&2
          echo "claude-vm:   Point 'source:' at a path with no comma in it (this one resolves to '$expanded')." >&2
          bad=1
          ;;
      esac
      # DIRECTORY: hides an entire subtree, so ON, ABOVE and INSIDE a system
      # path are all the same defect and all rejected.
      for sp in $CLAUDE_VM_GUEST_SYSTEM_PATHS; do
        claude_vm_guest_paths_overlap "$gpath" "$sp" || continue
        echo "claude-vm: mounts entry #${idx} ('$src') would mount at '$gpath', which overlaps the guest OS" >&2
        echo "claude-vm:   path '$sp'. Linux STACKS a mount: whatever the image has there becomes" >&2
        echo "claude-vm:   unreachable for the life of the VM, and the mount phase runs FIRST, so the" >&2
        echo "claude-vm:   breakage surfaces later as something unrelated (path: /root hides HOME before the" >&2
        echo "claude-vm:   credential seed writes /root/.claude into it). Mount a directory under" >&2
        echo "claude-vm:   $CLAUDE_VM_GUEST_MOUNT_ROOT/<tag> (the default), /srv or /opt instead. A single" >&2
        echo "claude-vm:   FILE source may land inside $CLAUDE_VM_GUEST_USER_FILE_PATHS -- it replaces one" >&2
        echo "claude-vm:   file rather than a whole subtree." >&2
        bad=1
        break
      done
    fi
    # Whole-string equality against each mountpoint already seen. The
    # `${a[@]+"${a[@]}"}` guard is for the FIRST entry, when the array is still
    # empty: bash 3.2 (the /bin/bash macOS ships) treats a bare "${a[@]}" on an
    # empty array as an unbound variable under `set -u` and kills the launcher.
    dup=0
    for spath in ${seen_paths[@]+"${seen_paths[@]}"}; do
      [ "$spath" = "$gpath" ] || continue
      echo "claude-vm: mounts entry #${idx} ('$src') would mount at '$gpath', where an earlier entry already" >&2
      echo "claude-vm:   mounts. The later mount shadows the earlier one, so one of the two directories is" >&2
      echo "claude-vm:   unreachable inside the guest. Give it its own 'path:' (the default is" >&2
      echo "claude-vm:   $CLAUDE_VM_GUEST_MOUNT_ROOT/<tag>)." >&2
      bad=1
      dup=1
      break
    done
    [ "$dup" -eq 1 ] || seen_paths+=("$gpath")
  done < <(claude_vm_mount_specs "$boot_doc")
  [ "$bad" -eq 0 ]
}

# ---------------------------------------------------------------------
# Guest-capability schema accessors (issue #103): packages, Claude
# permissions/marketplaces/plugins, and GitHub auth. The schema +
# merge landed in #103; the settings-rendering consumer
# (claude_vm_render_guest_settings, below) landed in #104. The remaining
# consumers (image build, boot install, egress derivation) land in sibling
# slices under #39.

# Emit a flat string list, one entry per line, from a merged-config file.
#   $1 -- merged config file path
#   $2 -- yq path expression to the list (e.g. '.packages')
claude_vm_list_items() {
  local file="$1" path="$2"
  yq eval "${path} // [] | .[]" "$file" 2>/dev/null
}

# Emit apt_sources as tab-separated "name<TAB>repo<TAB>key_url" lines from
# a merged-config file. key_url is optional per-entry; `(.key_url // "")`
# emits an empty field for a missing/null key_url rather than the LITERAL
# string "null" that a bare `.key_url | @tsv` would render for a null yq
# value.
claude_vm_apt_sources() {
  local file="$1"
  yq eval '
    .apt_sources // [] | .[]
    | [(.name // ""), (.repo // ""), (.key_url // "")] | @tsv
  ' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------
# Boot-time apt derived egress (issue #106).
#
# Boot-file `packages:` (install at boot) / `update_at_boot` install/refresh apt
# packages at guest boot, through the proxy -- so the Debian mirror hosts
# (and any apt_sources hosts, bake or boot) must be reachable from the guest.
# The launcher adds them to the egress allowlist iff boot-time apt work is
# actually configured (add_apt_uris_to_allowlist: auto, the
# default) or unconditionally when the operator opts in
# (add_apt_uris_to_allowlist: always). See
# claude_vm_boot_apt_egress_needed (the "iff" gate) and
# claude_vm_apt_source_hosts (the per-entry host derivation) below.

# The two Debian mirror hosts every install_at_boot/update_at_boot needs
# regardless of any apt_sources -- the base image's /etc/apt/sources.list
# points at these.
CLAUDE_VM_DEBIAN_MIRROR_HOSTS="deb.debian.org security.debian.org"

# True (exit 0) when boot-time apt work is configured that needs the Debian
# mirrors/apt_sources hosts reachable from the guest -- i.e. the launcher
# should derive and add apt egress to the allowlist. False (exit 1) means
# "auto, and nothing configured" -- a hard-secure all-baked config leaves
# package repos unreachable from the guest by design.
#
#   $1 -- merged BOOT document file path
#
# True iff ANY of (boot-file schema paths):
#   - `packages:` (installed at boot) is nonempty
#   - `update_at_boot` is true (default true)
#   - `add_apt_uris_to_allowlist` is "always" (default "auto")
claude_vm_boot_apt_egress_needed() {
  local file="$1"
  local mode
  mode="$(claude_vm_scalar "$file" '.add_apt_uris_to_allowlist' "$CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST")"
  if [ "$mode" = "always" ]; then
    return 0
  fi
  if [ -n "$(claude_vm_list_items "$file" '.packages')" ]; then
    return 0
  fi
  local update_at_boot
  update_at_boot="$(claude_vm_bool_scalar "$file" '.update_at_boot' "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT")"
  [ "$update_at_boot" = "true" ]
}

# Emit the hostnames parsed out of both tiers' apt_sources repo/key_url URIs,
# one per line, de-duplicated. Used (alongside CLAUDE_VM_DEBIAN_MIRROR_HOSTS)
# to derive the egress hosts a boot-time apt_sources render needs.
#
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
#
# Boot-time apt talks to the hosts of BOTH tiers' apt_sources: a baked source
# is already rendered into the image's /etc/apt, so `apt-get update` at boot
# still reaches its host, and a boot-declared source is rendered at boot --
# hence both documents feed the derived-egress host set.
#
# repo is an apt one-line source (e.g. "deb [signed-by=...] https://HOST/path
# suite component"); the host is the authority component of its URI, wherever
# it appears in the line. key_url is a plain URL. Both are parsed with the
# same permissive extraction: find an http(s):// URI, strip the scheme, drop
# any userinfo@ prefix, then drop a :port suffix (this codebase's egress
# allowlists are host-only, so a port suffix would never match). Entries with
# no parseable http(s) URI contribute nothing (e.g. a key_url left empty, or a
# repo line this permissive scan cannot find a URI in) rather than aborting --
# host derivation degrades quietly, matching the rest of this file's "missing
# input -> empty, not an error" convention.
claude_vm_apt_source_hosts() {
  local bake_doc="$1" boot_doc="$2" f
  # Emit repo/key_url as a flat YAML LIST (not a bare comma-expression) so an
  # entry with no key_url still contributes its "" placeholder line rather
  # than silently dropping the NEXT entry's key_url -- a comma-expression
  # (`(.repo // ""), (.key_url // "")` per .[] element) was observed to
  # collapse output across array elements under yq v4.53 when an element
  # produced an empty second branch.
  for f in "$bake_doc" "$boot_doc"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    yq eval '
      .apt_sources // [] | .[]
      | [(.repo // ""), (.key_url // "")] | .[]
    ' "$f" 2>/dev/null
  done \
    | grep -oE 'https?://[^/[:space:]]+' \
    | sed -E 's#^https?://##; s/^[^@]*@//; s/:.*$//' \
    | sort -u
}

# ---------------------------------------------------------------------
# Bake-relevant config canonicalization + bake-hash (issue #105).
#
# The guest image bakes the bake file's `packages:` into the mkosi Packages= list
# and renders its `apt_sources:` into the build (keyring + sources.list.d).
# Two configs that bake the SAME thing must share ONE cached image; two
# that bake different things must get SEPARATE cached variants. So the
# image cache key gains a "bake-hash" segment derived from -- and ONLY
# from -- the bake-relevant config, canonicalized so cosmetic differences
# (list order, key order, a missing-vs-empty key_url) do not fork the cache.
#
# The hash DELIBERATELY excludes everything else in the merged config
# (cpus, egress, permissions, plugins, ...): those do not change what is
# baked into the image, so they must not trigger a rebuild. Plugin /
# marketplace freshness is handled by the update_at_boot knobs, not the
# bake-hash; when the marketplaces/plugins bake slice lands it will EXTEND
# this canonical input with the plugin/marketplace refs (a one-time
# rebuild), which is why the canonical form is a structured object rather
# than an opaque string -- a future key can be added without disturbing the
# existing hash for configs that set no plugins.

# Emit the CANONICAL bake-relevant config as compact JSON on stdout, from a
# merged-config file. This is the single canonical form the bake-hash is
# computed over AND that the launcher passes to build-guest-image.sh, so the
# `--print-version` hash and the actual build always agree by construction.
#
#   $1 -- merged config file path
#
# Canonicalization rules:
#   - `packages:` (bake)   -> the list, with null/empty-string entries STRIPPED
#                            (a YAML `null` list entry, e.g. from a stray `-`
#                            or a trailing comma, would otherwise round-trip
#                            through yq's JSON encoder as the literal string
#                            "None" once it reaches the Python parser in
#                            podman-mkosi.sh, producing a bogus "None" package
#                            name in the mkosi Packages= list and failing the
#                            image build; an empty string is equally
#                            meaningless as a package name), then
#                            de-duplicated and SORTED (so order in the YAML
#                            does not change the hash).
#   - `apt_sources:`      -> each entry reduced to exactly {name, repo,
#                            key_url} with a missing/null field normalized to
#                            "" (so a missing vs. explicit-empty key_url hash
#                            identically), then the whole list SORTED by name
#                            (so declaration order does not change the hash).
#   - `env.set:` (issue #135) -> the map, SORTED by key (so declaration order
#                            does not change the hash) and with every value
#                            rendered as a STRING via `tostring`. An
#                            environment variable holds a string; `PORT: 8080`
#                            and `DEBUG: true` are YAML int/bool, and passing
#                            them through as JSON scalars would leave the
#                            provisioner's Python writing `8080`/`True` into a
#                            shell file -- `True` being wrong. `tostring`
#                            renders each exactly as yq renders the scalar
#                            (`8080`, `true`), which is what the operator
#                            wrote. Only `env.set` appears here: `env.copy` /
#                            `env.files` are boot-only and abort in a bake file
#                            (claude_vm_check_env), precisely so a host-read
#                            secret never becomes image bytes.
# An absent `packages:` / `apt_sources:` / `env.set:` all normalize to the
# empty collection, so a config with no bake-affecting overrides emits exactly
# `{"bake":[],"apt_sources":[],"env":{}}` -- a stable value shared across every
# such config (the "shares the global image" case). Output is compact (-I=0) and
# key-ordered by the literal object constructor below, so it is byte-stable.
#
# Stripping null/empty bake entries here -- rather than at the one call site
# in podman-mkosi.sh that renders Packages= -- means every downstream
# consumer of this canonical JSON (the bake-hash, build-guest-image.sh's
# --print-version, and the in-container render) is covered by construction;
# a future second consumer cannot reintroduce the bug by skipping a guard.
claude_vm_bake_config_json() {
  local file="$1"
  yq eval -o=json -I=0 '
    {
      "bake": (.packages // [] | map(select(. != null and . != "")) | unique | sort),
      "apt_sources": (
        .apt_sources // []
        | map({
            "name":    (.name // ""),
            "repo":    (.repo // ""),
            "key_url": (.key_url // "")
          })
        | sort_by(.name)
      ),
      "env": (
        .env.set // {}
        | to_entries | sort_by(.key) | from_entries
        | map_values(. | tostring)
      )
    }
  ' "$file" 2>/dev/null
}

# Compute the BAKE-HASH: the first 8 hex chars of the sha256 of the canonical
# bake-relevant config (claude_vm_bake_config_json). Printed on stdout with no
# trailing newline noise beyond a single \n.
#
#   $1 -- merged config file path
#
# NOTE: this hashes the MERGED bake config. Since issue #179 the image cache
# key + filename is instead a whole-file, raw-byte hash of the two BAKE FILES
# (claude_vm_image_identity_segments / claude_vm_file_identity_hash) -- no
# canonicalization, no key-picking. This helper is retained for the
# build-CONTENT canonicalization (CLAUDE_VM_BAKE_CONFIG) and for the older
# callers/tests that hash the merged bake config; it no longer drives the
# image filename. An empty bake config always yields the SAME hash (the
# canonical `{"bake":[],"apt_sources":[]}` is constant).
#
# sha256 tool resolution: prefer `shasum -a 256` (ships with macOS, the only
# supported host) and fall back to `sha256sum` (coreutils) so the helper works
# whether or not coreutils is installed. Both emit "<hex>  -" for stdin; cut
# takes the hex field and the ${hex:0:8} the 8-char prefix.
claude_vm_bake_hash() {
  local file="$1" json
  json="$(claude_vm_bake_config_json "$file")" || return 1
  claude_vm_bake_hash_from_json "$json"
}

# Compute the 8-hex bake-hash from an ALREADY-CANONICAL bake-config JSON string
# (as produced by claude_vm_bake_config_json). Split out from
# claude_vm_bake_hash so build-guest-image.sh can hash the canonical JSON the
# launcher hands it WITHOUT re-reading or re-canonicalizing the merged config
# (which would require yq in the build path and risk the two sides diverging).
# The launcher and the build script therefore hash the exact same bytes.
#
#   $1 -- canonical bake-config JSON (compact, from claude_vm_bake_config_json)
claude_vm_bake_hash_from_json() {
  local json="$1" hex
  if command -v shasum >/dev/null 2>&1; then
    hex="$(printf '%s' "$json" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
  elif command -v sha256sum >/dev/null 2>&1; then
    hex="$(printf '%s' "$json" | sha256sum 2>/dev/null | cut -d' ' -f1)"
  else
    echo "claude-vm: neither 'shasum' nor 'sha256sum' found to compute the bake-hash." >&2
    return 1
  fi
  # An empty hex (tool failure) is a hard error -- a truncated/empty variant
  # segment would silently collapse distinct bake configs onto one image.
  [ -n "$hex" ] || { echo "claude-vm: failed to compute bake-hash" >&2; return 1; }
  printf '%s\n' "${hex:0:8}"
}

# True (exit 0) when the merged config has NO bake-affecting entries -- i.e.
# the bake `packages:`, `apt_sources:` and `env.set:` are all empty/absent.
#
# NOTE: since issue #179 the launcher decides image identity via a whole-file,
# raw-byte hash of the two BAKE FILES (claude_vm_file_identity_hash), not this
# merged-config helper. Retained for the pure-function tests that still
# exercise the merged bake-config canonicalization.
#
#   $1 -- merged config file path
claude_vm_bake_config_is_empty() {
  local file="$1" count
  count="$(yq eval '
    ((.packages // []) | length) + ((.apt_sources // []) | length)
      + ((.env.set // {}) | length)
  ' "$file" 2>/dev/null)"
  [ "${count:-0}" = "0" ]
}

# ---------------------------------------------------------------------
# Image-identity hashing -- WHOLE-FILE, RAW BYTES (issue #179 redesign).
#
# The bake-hash / build-config-json functions above hashed a CANONICALIZED,
# key-PICKED projection of the config (bake packages, apt_sources,
# image.root_headroom_mb). That key-picking was a hand-maintained classification
# every future build-affecting knob had to remember to update: a missed
# build-affecting key silently reused a stale image; a wrongly-included runtime
# key forced spurious multi-minute rebuilds. Nothing structural caught either
# mistake.
#
# Issue #179 deletes the classification entirely by SPLITTING the config into
# bake vs boot FILES (config-bake.yml / config-boot.yml, per tier) and hashing
# the WHOLE bake FILE's raw bytes. Placement of a key in the bake file IS the
# classification -- made once, visibly, by the operator. A knob in the wrong
# file loudly does nothing (a boot key in the bake file changes the hash but the
# launcher never reads it as a runtime knob; a bake key in the boot file never
# reaches the image) instead of silently poisoning the cache.
#
# Hashing is over the RAW FILE BYTES with NO canonicalization: list order, key
# order, whitespace, and a trailing-newline toggle ALL change the hash. That is
# deliberate -- a trailing-newline toggle is the documented force-rebuild lever.
# Boot files never feed the identity, so editing egress/cpus/boot-packages/
# update_at_boot never rebuilds.
#
# The composed image identity is self-documenting:
#
#   - repo with NO repo-bake file:  <base>+global<globalhash>
#   - repo WITH a repo-bake file:   <base>+global<globalhash>+<reponame>-<repohash>
#
# where <globalhash> is the raw-byte hash of the GLOBAL bake file and
# <repohash> is the raw-byte hash of the REPO bake file. Every repo without a
# repo-bake file shares one image keyed on the global-bake hash; a repo WITH a
# repo-bake file gets its own image, disambiguated by its NAME (two repos with
# byte-identical repo-bake content still get two images -- legibility over
# maximal dedup, the human's explicit choice: you can see whose override runs
# where).

# Compute the 8-hex WHOLE-FILE identity hash of a single BAKE config file over
# its RAW BYTES (no canonicalization). Reuses the same sha256 tool resolution as
# claude_vm_bake_hash_from_json so tool choice + prefix length stay consistent.
#
# A MISSING file hashes as the fixed sentinel "00000000" -- the stable
# "no bake file present" identity. This is only ever consumed for the GLOBAL
# bake file (a missing global bake file yields global00000000, shared by every
# repo whose global bake file is likewise absent); a missing REPO bake file
# contributes NO segment at all (see claude_vm_image_identity_segments), so its
# hash is never rendered.
#
#   $1 -- a SINGLE bake config file path (config-bake.yml). Missing -> sentinel.
claude_vm_file_identity_hash() {
  local file="$1" hex
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    printf '%s\n' "00000000"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    hex="$(shasum -a 256 < "$file" 2>/dev/null | cut -d' ' -f1)"
  elif command -v sha256sum >/dev/null 2>&1; then
    hex="$(sha256sum < "$file" 2>/dev/null | cut -d' ' -f1)"
  else
    echo "claude-vm: neither 'shasum' nor 'sha256sum' found to compute the image identity hash." >&2
    return 1
  fi
  [ -n "$hex" ] || { echo "claude-vm: failed to compute the image identity hash for '$file'" >&2; return 1; }
  printf '%s\n' "${hex:0:8}"
}

# Sanitize a repo name for use as an image-filename / version segment: keep
# only [A-Za-z0-9._-], collapse every other run to a single '-', and trim
# leading/trailing '-'. The repo name is a directory basename (operator's
# checkout path), so it can contain spaces or other characters that would
# corrupt a filename or version string; this makes it filename-safe while
# staying human-legible. An empty result (e.g. a name that was all separators)
# falls back to "repo" so a segment is always well-formed.
#
#   $1 -- raw repo name (typically basename of the repo root)
claude_vm_sanitize_repo_name() {
  local raw="$1" clean
  clean="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  [ -n "$clean" ] || clean="repo"
  printf '%s\n' "$clean"
}

# Compose the image-identity variant segment(s) appended to the base version /
# image filename, from the two BAKE FILES and the repo name (issue #179).
#
#   $1 -- global BAKE file path (config-bake.yml; may be absent)
#   $2 -- repo BAKE file path   (config-bake.yml; may be absent)
#   $3 -- repo name (raw; sanitized internally). Only used when a repo-bake file
#         exists and thus contributes a segment.
#
# Emits (on stdout, no leading '+'):
#   - repo with NO repo-bake file:  "global<globalhash>"
#   - repo WITH a repo-bake file:   "global<globalhash>+<reponame>-<repohash>"
#
# The GLOBAL segment is ALWAYS present (a missing global bake file hashes to the
# fixed "00000000" sentinel) so every image name states which global bake it
# came from. The repo segment appears IFF a repo-bake FILE EXISTS -- its mere
# presence (not its content) gates the segment: a repo that ships a repo-bake
# file gets its own image even if that file is byte-identical to another repo's,
# because the repo NAME disambiguates it (legibility over dedup). A repo with
# only a repo-BOOT file (no repo-bake file) contributes NO segment and shares
# the global image.
claude_vm_image_identity_segments() {
  local global_bake="$1" repo_bake="$2" repo_name="$3"
  local ghash rhash rname out
  ghash="$(claude_vm_file_identity_hash "$global_bake")" || return 1
  out="global${ghash}"
  if [ -n "$repo_bake" ] && [ -f "$repo_bake" ]; then
    rhash="$(claude_vm_file_identity_hash "$repo_bake")" || return 1
    rname="$(claude_vm_sanitize_repo_name "$repo_name")"
    out="${out}+${rname}-${rhash}"
  fi
  printf '%s\n' "$out"
}

# Emit marketplaces as tab-separated "name<TAB>url" lines from a
# merged-config file. url is optional per-entry; `(.url // "")` emits an
# empty field for a missing/null url rather than the literal string
# "null" (same rationale as claude_vm_apt_sources above).
claude_vm_marketplaces() {
  local file="$1"
  yq eval '
    .claude.marketplaces // [] | .[]
    | [(.name // ""), (.url // "")] | @tsv
  ' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------
# Config-driven marketplaces + plugins (issue #107).
#
# BAKE/BOOT PLACEMENT. Issue #107's design predates the #179 four-file split,
# so it still speaks of "extending the #105 bake-hash with marketplace/plugin
# refs". Under #179 that extension is not a new hash input at all -- PLACEMENT
# is the classification, and the image identity is already a whole-file
# raw-byte hash of the BAKE files. So the keys land like this, mirroring the
# `packages:` / `apt_sources:` precedent exactly:
#
#   claude.plugins.bake              -> BAKE file ONLY. It changes image bytes
#                                       (plugins are installed into the image's
#                                       /root/.claude/plugins), so the
#                                       whole-file bake hash covers it for
#                                       free: edit it and the image rebuilds.
#   claude.plugins.install_at_boot   -> BOOT file ONLY (run-time install).
#   claude.plugins.update_at_boot    -> BOOT file ONLY (run-time freshness).
#   claude.plugins.add_marketplace_uris_to_allowlist
#                                    -> BOOT file ONLY (run-time egress).
#   claude.plugins.enabled           -> BOOT file ONLY (settings.json toggle;
#                                       no reinstall, so no image change).
#   claude.marketplaces              -> BOTH files, unioned + deduped by name,
#                                       exactly like apt_sources. A marketplace
#                                       is needed at BAKE time (to install the
#                                       bake set) AND at BOOT time (to install
#                                       install_at_boot and to update), and a
#                                       boot-only marketplace must not force an
#                                       image rebuild.
#
# A key in the WRONG file would otherwise parse fine and never be read -- the
# exact silent no-op #179 set out to make impossible. `claude.plugins` is the
# one map that legitimately appears in BOTH file types, which makes a
# misplaced sub-key unusually easy to write, so
# claude_vm_check_plugin_key_placement (below) turns each misplacement into a
# LOUD abort rather than a silent drop.

# The claude.plugins sub-keys that belong in the BAKE file, and those that
# belong in the BOOT file. Used by claude_vm_check_plugin_key_placement to
# reject a misplaced key. Kept as data so a future key joins the guard by
# being listed once.
CLAUDE_VM_PLUGIN_BAKE_ONLY_KEYS=(
  'bake'
)
CLAUDE_VM_PLUGIN_BOOT_ONLY_KEYS=(
  'install_at_boot'
  'update_at_boot'
  'add_marketplace_uris_to_allowlist'
  'enabled'
)

# Does a RAW config file carry the claude.plugins sub-key $2? Returns 0 when it
# does. A PRESENCE test (`has`), not a value test, and asked of the file the
# operator WROTE rather than of a merged document -- for the same reason
# claude_vm_env_bake_has_key is (see its header): the merge destroys presence,
# in TWO different ways, and misplacement is a property of what was written.
#
#   - `.claude.plugins.bake` and `.claude.plugins.install_at_boot` are
#     CLAUDE_VM_LIST_KEYS, so a valueless `bake:`, a `bake: []` and a
#     `bake: ""` all merge to an empty list, claude_vm_prune_empty_skeleton's
#     pass 1 deletes the key, and its pass 2 deletes the `plugins:` map left
#     empty as a result.
#   - EVERY sub-key, list key or not, written as an empty MAP (`enabled: {}`)
#     is deleted by that same pass 2, which removes any empty map wherever it
#     sits.
#   - a VALUELESS sub-key of any kind reaches the merged document as a genuine
#     null, which `!= null` also answered false for. Only the artificial
#     global-file-with-no-repo-file layering coerced it to '' (the deep merge
#     against the empty document), so the old gate's verdict on one and the
#     same config depended on which layer the file sat in.
#
# Measured through the real claude_vm_merge_config against yq v4.53.3: with the
# gate asking `(.claude.plugins.<key> != null)` of the merged document, all four
# empty spellings of `bake` / `install_at_boot`, and the valueless and `{}`
# spellings of `update_at_boot` / `add_marketplace_uris_to_allowlist` /
# `enabled`, answered *false* and the launch proceeded. Only `: []` and `: ""`
# on a NON-list key were caught, because no prune pass reaches those.
# config-test.sh's negative control holds both halves of that fact.
#   $1 -- a RAW config file path (bake or boot, global or repo), pre-merge
#   $2 -- the claude.plugins sub-key ('bake', 'enabled', ...)
claude_vm_plugin_raw_has_key() {
  local file="$1" key="$2" present
  [ -n "$file" ] && [ -f "$file" ] || return 1
  present="$(yq eval "(((.claude // {}).plugins // {}) | has(\"${key}\"))" "$file" 2>/dev/null)"
  [ "$present" = "true" ]
}

# Abort (non-zero + a claude-vm: diagnostic) when a claude.plugins sub-key
# appears in the file type that never reads it. Without this the key parses,
# merges, and is silently ignored -- e.g. `claude.plugins.bake` written into
# config-boot.yml would leave the operator with an image that bakes NO plugins
# and no indication why.
#
# Takes the four RAW config paths and no merged document, because after the
# conversion to a presence test there is nothing left for a merged document to
# answer: a key present in a merged tier is present in one of that tier's two
# raw files by construction, so raw presence is a strict superset of the value
# test this replaced. Both DIRECTIONS need raw paths -- a BOOT-only key is
# hunted in the two BAKE files, a BAKE-only key in the two BOOT files -- which
# is why this gate takes four paths where claude_vm_check_env takes the bake
# pair only. Naming the file in the diagnostic is not decoration: with a global
# and a repo file per tier, "a config-bake.yml" leaves the operator two places
# to look.
#   $1 -- RAW global BAKE config file path (may be empty or absent)
#   $2 -- RAW repo   BAKE config file path (may be empty or absent)
#   $3 -- RAW global BOOT config file path (may be empty or absent)
#   $4 -- RAW repo   BOOT config file path (may be empty or absent)
claude_vm_check_plugin_key_placement() {
  local global_bake="$1" repo_bake="$2" global_boot="$3" repo_boot="$4"
  local key f bad=0
  for key in "${CLAUDE_VM_PLUGIN_BOOT_ONLY_KEYS[@]}"; do
    for f in "$global_bake" "$repo_bake"; do
      claude_vm_plugin_raw_has_key "$f" "$key" || continue
      echo "claude-vm: 'claude.plugins.${key}' is a BOOT key but was found in a config-bake.yml ($f)." >&2
      echo "claude-vm:   move it to config-boot.yml -- the bake files only feed the image build," >&2
      echo "claude-vm:   so it would parse here and never be read." >&2
      bad=1
    done
  done
  for key in "${CLAUDE_VM_PLUGIN_BAKE_ONLY_KEYS[@]}"; do
    for f in "$global_boot" "$repo_boot"; do
      claude_vm_plugin_raw_has_key "$f" "$key" || continue
      echo "claude-vm: 'claude.plugins.${key}' is a BAKE key but was found in a config-boot.yml ($f)." >&2
      echo "claude-vm:   move it to config-bake.yml -- baked plugins change the guest image's bytes," >&2
      echo "claude-vm:   so they must live where the image-identity hash can see them." >&2
      bad=1
    done
  done
  [ "$bad" -eq 0 ]
}

# ---------------------------------------------------------------------
# Guest environment variables (issue #135): env.set / env.copy / env.files.
#
# The tier a sub-key may be declared in follows from HOW its value is obtained,
# not from operator preference:
#
#   env.set    bake + boot   explicit literal written in the config
#   env.copy   boot ONLY     read from the HOST environment at launch
#   env.files  boot ONLY     read from a host `.env` file at launch
#
# A bake file is consumed at image-build time and its result is image BYTES that
# persist across every run of that image; a boot file is consumed per launch and
# its result rides the transient claudecreds mount, which cleanup() shreds on
# exit. `env.copy` / `env.files` resolve against the host environment, which
# does not exist at image-build time, and a value read from it is exactly the
# kind of secret that must never become image bytes -- so only explicitly
# written literals are bakeable, and the two host-sourced sub-keys are a hard
# abort in a bake file (claude_vm_check_env below).
#
# Precedence, lowest to highest:
#
#   bake env.set  <  boot env.files  <  boot env.copy  <  boot env.set
#
# Within each tier, repo-over-global (per key for `set`, union for
# `copy`/`files`); within `env.files`, later files win over earlier ones. The
# whole chain is implemented by EMISSION ORDER rather than by a dedup pass:
# claude_vm_resolve_boot_env emits files, then copy, then set, and the guest
# sources the bake file before the boot one, so a later assignment simply
# overwrites an earlier one when the file is sourced under `set -a`. That needs
# no associative array and therefore no bash 4 (see the bash-3.2 rule in
# CLAUDE.md -- these run as config-load guards).

# The sub-keys of `env:` that a BAKE file may not carry. Data, so a future
# host-sourced sub-key joins the gate by being listed once.
CLAUDE_VM_ENV_BOOT_ONLY_KEYS=(
  'copy'
  'files'
)

# The environment variables the LAUNCHER itself composes -- every name written
# into run.env (claude-vm.sh) plus the one the boot launcher exports on its
# abnormal-exit path (build-guest-image.sh). A config entry naming one of these
# is a mistake rather than an override, and honouring it would be worse than
# useless: the guest sources run.env FIRST and these env files immediately
# after, so a config value would actually WIN -- silently replacing the proxy
# the guest reaches the network through, a mount tag, or claude's own argv, and
# breaking the boot in a way that looks nothing like a config error.
# CLAUDE_VM_LAST_CLAUDE_STATUS is the one exception in the other direction: the
# boot launcher exports it long after both files are sourced, so a config entry
# for it would be silently overwritten instead. Refusing at load covers both.
# Space-delimited and matched with a space-padded `case`, the
# same shape as CLAUDE_VM_RESERVED_MOUNT_TAGS -- sound here for the same reason
# it is there: an environment-variable name is charset-validated to
# [A-Za-z_][A-Za-z0-9_]* before the membership test, so it can never contain
# the delimiter.
CLAUDE_VM_RESERVED_ENV_NAMES="HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy REPO_TAG POLICY_TAG CLAUDEBIN_TAG CLAUDECREDS_TAG CLAUDE_VM_COLUMNS CLAUDE_VM_LINES CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN CLAUDE_CODE_NO_FLICKER DISABLE_AUTOUPDATER IS_SANDBOX CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT CLAUDE_ARGS CLAUDE_VM_LAST_CLAUDE_STATUS"

# Is $1 a usable environment-variable name -- [A-Za-z_][A-Za-z0-9_]*? Returns 0
# when it is. This is POSIX's own name charset, and it is not merely
# conventional here: the name is emitted as the left-hand side of a shell
# assignment that the guest sources under `set -a`, so anything outside it is
# either a syntax error in the guest or (with a `=` or a newline in it) a way to
# smuggle a second assignment past the reader.
claude_vm_env_name_is_valid() {
  case "$1" in
    ''|[!A-Za-z_]*)   return 1 ;;
    *[!A-Za-z0-9_]*)  return 1 ;;
  esac
  return 0
}

# Is $1 a launcher-owned environment variable (CLAUDE_VM_RESERVED_ENV_NAMES)?
# Returns 0 when it is. Kept as a function rather than an inline `case` so the
# suite can call it from inside a `$( )` -- an inline `case` there mis-parses on
# bash 3.2, whose command substitution ends at the pattern's own `)`.
claude_vm_env_name_is_reserved() {
  case " $CLAUDE_VM_RESERVED_ENV_NAMES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Emit the NAMES declared under `env.set` in a merged document, one per line, in
# document order. Names only: the VALUE is fetched per-name by
# claude_vm_env_set_value below rather than travelling in a shared record,
# because a value may legitimately contain a tab or a newline and yq's `@tsv`
# would escape those into a literal `\t` / `\n` -- silently changing the value
# an operator wrote. One yq call per variable is affordable (this map holds a
# handful of entries) and needs no escaping contract at all.
#   $1 -- merged config document file path
claude_vm_env_set_names() {
  local file="$1"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  yq eval '.env.set // {} | keys | .[]' "$file" 2>/dev/null
}

# The yq TAG of one `env.set` value (`!!str`, `!!int`, `!!bool`, `!!seq`,
# `!!map`, `!!null`, ...), used by claude_vm_check_env to reject a value that is
# not a scalar. `!!null` comes back both for an absent key and for an explicitly
# valueless one; only the latter can reach here, since the name came from
# claude_vm_env_set_names.
#   $1 -- merged config document file path
#   $2 -- the variable name (already charset-validated by the caller)
claude_vm_env_set_tag() {
  local file="$1" name="$2"
  yq eval ".env.set[\"${name}\"] | tag" "$file" 2>/dev/null
}

# The VALUE of one `env.set` entry, rendered exactly as yq renders the scalar
# (an int as its digits, a bool as `true`/`false`, an empty string as nothing)
# and %q-quoted, so what comes back is a ready-to-source right-hand side rather
# than raw bytes.
#
# The quoting happens HERE rather than at the call site because the value's own
# trailing newlines are only intact here. yq terminates its output with exactly
# one `\n` of its own, and `$(...)` strips ALL trailing newlines -- so a caller
# capturing the raw bytes cannot tell `X: "a\nb"` from `X: "a\nb\n\n"`, and
# silently ships the operator a shorter value than the one they wrote. The bake
# tier has no such loss (claude_vm_bake_config_json carries the value inside
# JSON, and the provisioner's Python shlex.quotes it byte-exactly), so leaving
# it here would make the two tiers disagree about the same literal.
#
# The sentinel below is what closes that: append a byte that is not a newline,
# strip it, then strip the ONE `\n` yq added -- which leaves every newline the
# operator wrote. `%q` renders those as `$'a\nb\n'`, so the emitted line carries
# no literal newline at all and the caller's own `$(...)` has nothing left to
# eat. Verified to round-trip through `set -a` sourcing on both bash 3.2 and
# bash 5.
#   $1 -- merged config document file path
#   $2 -- the variable name (already charset-validated by the caller)
claude_vm_env_set_value() {
  local file="$1" name="$2" raw
  raw="$(yq eval ".env.set[\"${name}\"]" "$file" 2>/dev/null; printf 'x')"
  raw="${raw%x}"
  raw="${raw%$'\n'}"
  printf '%q\n' "$raw"
}

# Emit the `env.copy` names / the `env.files` paths of a merged BOOT document,
# one per line. Thin named wrappers over claude_vm_list_items so every reader
# names the same yq path and a future rename lands in one place.
claude_vm_env_copy_names() {
  claude_vm_list_items "$1" '.env.copy'
}
claude_vm_env_files() {
  claude_vm_list_items "$1" '.env.files'
}

# Does a bake config file carry the boot-only `env` sub-key $2? Returns 0 when
# it does. A PRESENCE test (`has`), not a value test, for the same reason
# claude_vm_mount_mode_entries asks `has("mode")`: `copy: ""`, a valueless
# `copy:` and an omitted `copy:` all render as the same empty value, and
# silently ignoring the first two would leave an operator believing a host
# variable is being forwarded into every session of a persistent image.
#
# $1 is the RAW file the operator wrote -- never a MERGED document. Presence is
# a property of what was WRITTEN, and the merge deliberately destroys it:
# `.env.copy` and `.env.files` are CLAUDE_VM_LIST_KEYS, so a valueless `copy:`
# merges to an empty list, claude_vm_prune_empty_skeleton's pass 1 deletes it,
# pass 2 deletes the `env:` map left empty as a result, and `has("copy")` on the
# merged document answers false. That prune is correct and its whole purpose is
# to stop a consumer testing "did the user configure this?" by key presence on a
# merged document; the answer is to ask the raw files instead, not to carve the
# two keys out of the prune. (Asking the merged document is what shipped in the
# first round of issue #135: a valueless `copy:` in a bake file was accepted and
# the image built, verified by a real launch. config-test.sh's negative control
# holds that shape.)
#   $1 -- a RAW bake config file path (global or repo), pre-merge
#   $2 -- the sub-key ('copy' or 'files')
claude_vm_env_bake_has_key() {
  local file="$1" key="$2" present
  [ -n "$file" ] && [ -f "$file" ] || return 1
  present="$(yq eval "((.env // {}) | has(\"${key}\"))" "$file" 2>/dev/null)"
  [ "$present" = "true" ]
}

# Parse a host `.env` file into ready-to-source assignment lines, one per
# declared variable: `NAME=<shell-quoted value>`. Prints nothing and returns 1,
# after a claude-vm: diagnostic, when the file is missing or a line does not
# parse.
#
# The accepted grammar is deliberately the small, portable one every `.env`
# convention agrees on, because this file is the operator's, written for some
# other tool, and claude-vm only reads it:
#
#   - a blank line, or one whose first non-blank character is `#`, is a comment
#   - an optional leading `export ` is allowed and dropped
#   - everything else must be NAME=VALUE, with NAME in [A-Za-z_][A-Za-z0-9_]*
#   - a VALUE wholly wrapped in matching single or double quotes is unwrapped
#     (the quotes are the .env convention's, not part of the value)
#
# There is NO variable expansion and no escape processing: the value is taken
# literally, so a `$` or a backslash means itself. The output is %q-quoted, so
# what the guest ends up with is byte-identical to what the file held.
#
# Never prints a VALUE, in a diagnostic or anywhere else -- a `.env` file is
# exactly where a third-party API key lives. The line NUMBER localises a parse
# error without quoting its contents.
#   $1 -- host path to the .env file (already ~-expanded by the caller)
claude_vm_env_file_assignments() {
  local file="$1" line lineno=0 name value first last env_tab
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "claude-vm: env.files entry '$file' is not a file on this host." >&2
    return 1
  fi
  # Held in a variable rather than written inline: a literal tab inside a `case`
  # pattern is invisible in a diff and one reformatting pass away from becoming
  # a space.
  env_tab=$'\t'
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Strip leading blanks so an indented comment is still a comment.
    while :; do
      case "$line" in
        ' '*|"$env_tab"*) line="${line#?}" ;;
        *) break ;;
      esac
    done
    case "$line" in
      ''|'#'*) continue ;;
      'export '*) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) : ;;
      *)
        echo "claude-vm: $file line $lineno does not parse as NAME=value." >&2
        echo "claude-vm:   env.files reads plain 'NAME=value' lines (blank lines and '#' comments are skipped)." >&2
        return 1
        ;;
    esac
    name="${line%%=*}"
    value="${line#*=}"
    if ! claude_vm_env_name_is_valid "$name"; then
      echo "claude-vm: $file line $lineno declares '$name', which is not a usable environment-variable name" >&2
      echo "claude-vm:   ([A-Za-z_][A-Za-z0-9_]*). The guest sources these as shell assignments." >&2
      return 1
    fi
    # Unwrap a value wrapped in matching quotes. Length >= 2 so a lone quote
    # character is left as the value it is.
    if [ "${#value}" -ge 2 ]; then
      first="${value:0:1}"
      last="${value:${#value}-1:1}"
      if [ "$first" = "$last" ] && { [ "$first" = '"' ] || [ "$first" = "'" ]; }; then
        value="${value#?}"
        value="${value%?}"
      fi
    fi
    printf '%s=%q\n' "$name" "$value"
  done < "$file"
  return 0
}

# Abort (non-zero + claude-vm: diagnostics) on every `env:` mistake that is
# knowable before the VM starts. Hard abort, never warn-and-limp: each case
# below ends with the guest missing a variable it was configured to have, and a
# session that boots without it fails much later, deep inside a tool call, with
# an opaque auth error that names nothing.
#
#   $1   -- merged BAKE document file path
#   $2   -- merged BOOT document file path
#   $3.. -- the RAW bake config file paths (global, repo), pre-merge. The
#           boot-only-sub-key case below is a PRESENCE test, and presence is a
#           property of what the operator WROTE: the merge unions `.env.copy` /
#           `.env.files` as list keys and then prunes them (with the `env:` map
#           holding them) when they resolve to nothing, so a valueless `copy:`
#           is invisible in $1. Each path may be empty or absent -- a bake file
#           that does not exist carries no key.
#
# The cases:
#   - `env.copy` / `env.files` present in a RAW bake file (presence, not value).
#   - `env.set` that is not a MAP, in either document.
#   - a name outside [A-Za-z_][A-Za-z0-9_]*, from any source (a `set` key, a
#     `copy` entry, a name declared by an `env.files` file).
#   - a name the LAUNCHER owns (CLAUDE_VM_RESERVED_ENV_NAMES).
#   - an `env.set` value that is not a scalar, or is explicitly valueless.
#   - an `env.files` path that is not on the host, or that does not parse.
#   - an `env.copy` name that is unset or EMPTY in this launcher's own
#     environment.
#
# Never prints a VALUE. Every diagnostic names the variable, the entry or the
# file, and stops there -- these are exactly the values that must not reach a
# terminal or a log.
claude_vm_check_env() {
  local bake_doc="$1" boot_doc="$2" bad=0
  local key name tag value f doc tier idx expanded assignment raw_bake
  shift 2
  # (a) the boot-only sub-keys, in the bake tier -- asked of each RAW bake file
  # rather than of $bake_doc, because the merge prunes exactly the spelling this
  # test exists to catch (see claude_vm_env_bake_has_key's header). Naming the
  # file is not decoration: with a global and a repo bake file, "a
  # config-bake.yml" leaves the operator two places to look.
  for raw_bake in "$@"; do
    [ -n "$raw_bake" ] && [ -f "$raw_bake" ] || continue
    for key in "${CLAUDE_VM_ENV_BOOT_ONLY_KEYS[@]}"; do
      if claude_vm_env_bake_has_key "$raw_bake" "$key"; then
        echo "claude-vm: 'env.${key}' was found in a config-bake.yml ($raw_bake), but it is a BOOT-only sub-key." >&2
        echo "claude-vm:   it resolves against the HOST environment at LAUNCH, which does not exist while the" >&2
        echo "claude-vm:   image is being built -- and a value read from it is exactly the kind of secret that" >&2
        echo "claude-vm:   must never become image bytes (the image persists across every run and is cloned" >&2
        echo "claude-vm:   per run). Move 'env.${key}' to config-boot.yml, where its values ride the transient" >&2
        echo "claude-vm:   credential mount and are shredded on exit. Only 'env.set' literals are bakeable." >&2
        bad=1
      fi
    done
  done
  # (b) env.set, in BOTH tiers: shape, names, and scalar-ness.
  for tier in BAKE BOOT; do
    case "$tier" in
      BAKE) doc="$bake_doc" ;;
      *)    doc="$boot_doc" ;;
    esac
    [ -n "$doc" ] && [ -f "$doc" ] || continue
    tag="$(yq eval '.env.set | tag' "$doc" 2>/dev/null)"
    case "$tag" in
      '!!map'|'!!null'|'') : ;;
      *)
        echo "claude-vm: 'env.set' in the merged ${tier} config is a ${tag}, not a map." >&2
        echo "claude-vm:   write it as 'NAME: value' pairs, one per variable." >&2
        bad=1
        continue
        ;;
    esac
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if ! claude_vm_env_name_is_valid "$name"; then
        echo "claude-vm: env.set key '$name' in the merged ${tier} config is not a usable environment-variable" >&2
        echo "claude-vm:   name ([A-Za-z_][A-Za-z0-9_]*). The guest sources these as shell assignments." >&2
        bad=1
        continue
      fi
      if claude_vm_env_name_is_reserved "$name"; then
        echo "claude-vm: env.set key '$name' in the merged ${tier} config names a variable the LAUNCHER owns." >&2
        echo "claude-vm:   claude-vm composes these itself: $CLAUDE_VM_RESERVED_ENV_NAMES." >&2
        echo "claude-vm:   the guest sources run.env BEFORE your env entries, so this one would overwrite the" >&2
        echo "claude-vm:   launcher's own value and break the boot rather than configuring anything." >&2
        bad=1
        continue
      fi
      tag="$(claude_vm_env_set_tag "$doc" "$name")"
      case "$tag" in
        '!!map'|'!!seq')
          echo "claude-vm: env.set['$name'] in the merged ${tier} config is a ${tag}. An environment variable" >&2
          echo "claude-vm:   holds a single scalar value; a map or a list has no environment representation." >&2
          bad=1
          ;;
        '!!null')
          echo "claude-vm: env.set['$name'] in the merged ${tier} config has no value. Give it one, or write" >&2
          echo "claude-vm:   '$name: \"\"' if you really mean the empty string -- claude-vm aborts rather than" >&2
          echo "claude-vm:   guessing, so you never believe a variable is set when it is not." >&2
          bad=1
          ;;
      esac
    done < <(claude_vm_env_set_names "$doc")
  done
  # (c) env.files: on the host, parseable, and every name it declares usable.
  # Parsed here, at load, rather than only when the boot env is written: a
  # missing or malformed file must abort BEFORE the image build and the VM
  # start, like every other config mistake.
  idx=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    idx=$((idx + 1))
    expanded="$(claude_vm_expand_mount_source "$f")"
    if ! assignment="$(claude_vm_env_file_assignments "$expanded")"; then
      echo "claude-vm:   (env.files entry #${idx}: '$f')" >&2
      bad=1
      continue
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      name="${name%%=*}"
      if claude_vm_env_name_is_reserved "$name"; then
        echo "claude-vm: env.files entry #${idx} ('$f') declares '$name', a variable the LAUNCHER owns." >&2
        echo "claude-vm:   claude-vm composes these itself: $CLAUDE_VM_RESERVED_ENV_NAMES." >&2
        echo "claude-vm:   remove that line, or point env.files at a file that does not set it." >&2
        bad=1
      fi
    done < <(printf '%s\n' "$assignment")
  done < <(claude_vm_env_files "$boot_doc")
  # (d) env.copy: usable names, not launcher-owned, and actually SET on this
  # host. The unset case is the loudest one on purpose -- forwarding nothing
  # silently is the worst outcome, since the guest then fails deep inside a tool
  # call with an error that names neither claude-vm nor the variable.
  idx=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    idx=$((idx + 1))
    if ! claude_vm_env_name_is_valid "$name"; then
      echo "claude-vm: env.copy entry #${idx} ('$name') is not a usable environment-variable name" >&2
      echo "claude-vm:   ([A-Za-z_][A-Za-z0-9_]*). env.copy lists NAMES to read from your shell, not values." >&2
      bad=1
      continue
    fi
    if claude_vm_env_name_is_reserved "$name"; then
      echo "claude-vm: env.copy entry #${idx} ('$name') names a variable the LAUNCHER owns." >&2
      echo "claude-vm:   claude-vm composes these itself: $CLAUDE_VM_RESERVED_ENV_NAMES." >&2
      echo "claude-vm:   the guest sources run.env BEFORE your env entries, so this one would overwrite the" >&2
      echo "claude-vm:   launcher's own value and break the boot rather than configuring anything." >&2
      bad=1
      continue
    fi
    # Indirect expansion, guarded for `set -u`: an unset name and an empty one
    # both land here, and both are refused.
    eval "value=\${${name}:-}"
    if [ -z "$value" ]; then
      echo "claude-vm: env.copy names '$name', but it is unset (or empty) in the environment claude-vm was" >&2
      echo "claude-vm:   launched from, so there is nothing to forward. Export it before launching -- from" >&2
      echo "claude-vm:   your shell profile, direnv, 'op run', or however you already supply it -- or remove" >&2
      echo "claude-vm:   it from env.copy. Refusing to boot a guest that silently lacks a key it was" >&2
      echo "claude-vm:   configured to have." >&2
      bad=1
    fi
  done < <(claude_vm_env_copy_names "$boot_doc")
  [ "$bad" -eq 0 ]
}

# Emit the BOOT tier's whole environment as ready-to-source `NAME=<shell-quoted
# value>` assignment lines, in PRECEDENCE ORDER: env.files first, then env.copy,
# then env.set. The launcher writes this into the transient claudecreds mount
# and the guest sources it under `set -a`, so a later line simply overwrites an
# earlier one -- which is the whole precedence implementation. No dedup pass, no
# associative array, and therefore nothing that needs bash 4.
#
# Assumes claude_vm_check_env has already run: every name here is valid,
# unreserved and (for env.copy) set on the host, and every env.files path parses.
# The `[ -n ]` guards below are the floor for a caller that runs without it.
#
#   $1 -- merged BOOT document file path
claude_vm_resolve_boot_env() {
  local boot_doc="$1" f name value expanded
  [ -n "$boot_doc" ] && [ -f "$boot_doc" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    expanded="$(claude_vm_expand_mount_source "$f")"
    claude_vm_env_file_assignments "$expanded" || return 1
  done < <(claude_vm_env_files "$boot_doc")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    claude_vm_env_name_is_valid "$name" || continue
    eval "value=\${${name}:-}"
    [ -n "$value" ] || continue
    printf '%s=%q\n' "$name" "$value"
  done < <(claude_vm_env_copy_names "$boot_doc")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    claude_vm_env_name_is_valid "$name" || continue
    # Already %q-quoted by the helper -- see its header for why the quoting
    # cannot happen here (this `$( )` would eat the value's own trailing
    # newlines). `%q` output never ends in a literal newline, so this capture is
    # lossless.
    value="$(claude_vm_env_set_value "$boot_doc" "$name")"
    printf '%s=%s\n' "$name" "$value"
  done < <(claude_vm_env_set_names "$boot_doc")
  return 0
}

# Abort when the SAME marketplace name appears with a DIFFERING url across the
# bake and boot documents. Byte-identical duplicates already collapsed under
# each tier merge's structural `unique`; a name whose de-duplicated entry list
# is longer than one carries conflicting content, and silently picking one url
# over the other would decide which code a `plugin@marketplace` ref resolves
# to. Same shape and rationale as claude_vm_check_apt_sources_conflicts.
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
claude_vm_check_marketplace_conflicts() {
  local bake_doc="$1" boot_doc="$2" dup
  dup="$(yq eval-all '
    ([select(fileIndex == 0) | .claude.marketplaces // [] | .[]]
      + [select(fileIndex == 1) | .claude.marketplaces // [] | .[]]) as $mps
    | ($mps | map(.name) | unique)
    | map(. as $n | {"name": $n, "n": [$mps[] | select(.name == $n)] | unique | length})
    | map(select(.n > 1))
    | .[].name
  ' "$bake_doc" "$boot_doc" 2>/dev/null)"
  if [ -n "$dup" ]; then
    echo "claude-vm: claude.marketplaces name conflict -- the following name(s) appear more than once with DIFFERING url across your bake/boot config files:" >&2
    printf '%s\n' "$dup" | while IFS= read -r n; do
      [ -n "$n" ] && echo "claude-vm:   - $n" >&2
    done
    echo "claude-vm: give each marketplace a unique name, or make the conflicting entries identical. Refusing to silently pick one url over the other." >&2
    return 1
  fi
  return 0
}

# Abort (non-zero + a claude-vm: diagnostic) when a claude.marketplaces entry
# carries no `name`, in either document. The name is the KEY of every
# marketplace record this file emits: the effective set de-duplicates by it,
# the origin stamp is a membership test on it, the guest's boot phase asks the
# CLI whether a marketplace of that name is registered, and a
# `plugin@marketplace` ref resolves against it. An entry with a url but no name
# is therefore unusable everywhere, and every reader's `[ -n "$name" ] || continue`
# guard would drop it without a word -- the operator declared a marketplace and
# silently got none. Say so at load instead.
#
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
claude_vm_check_marketplace_names() {
  local bake_doc="$1" boot_doc="$2" f tier mp_tab record name url idx bad=0
  mp_tab=$'\t'
  for tier in BAKE BOOT; do
    case "$tier" in
      BAKE) f="$bake_doc" ;;
      *)    f="$boot_doc" ;;
    esac
    [ -n "$f" ] && [ -f "$f" ] || continue
    idx=0
    while IFS= read -r record; do
      # Same empty-result-set guard as claude_vm_check_mounts: yq prints one
      # empty line for a document that declares no claude.marketplaces at all.
      [ -n "$record" ] || continue
      idx=$((idx + 1))
      name=${record%%$mp_tab*}
      url=${record#*$mp_tab}
      [ -n "$name" ] && continue
      echo "claude-vm: claude.marketplaces entry #${idx} in the merged ${tier} config has no name (url: '${url}')." >&2
      echo "claude-vm:   the name is what a 'plugin@marketplace' ref resolves against and what the guest" >&2
      echo "claude-vm:   checks registration by, so an unnamed entry can never be used." >&2
      echo "claude-vm:   give every claude.marketplaces entry a 'name:'." >&2
      bad=1
    done < <(claude_vm_marketplaces "$f")
  done
  [ "$bad" -eq 0 ]
}

# Emit the EFFECTIVE marketplace set as "name<TAB>url" lines: the union of both
# documents' claude.marketplaces, BAKE entries first, de-duplicated by NAME
# (conflicting urls under one name already aborted in
# claude_vm_check_marketplace_conflicts, so a later duplicate name here is
# byte-identical and safely dropped). Both the image build and the guest boot
# consume this same set, so a plugin ref resolves identically in either place.
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
#
# Records are split by hand, per the TSV RECORDS note above: an entry with a
# url but no name would otherwise read its URL as its name and be emitted as a
# marketplace called `https://...`. claude_vm_check_marketplace_names rejects
# that entry at load; the `[ -n "$name" ]` guard here is the floor for any
# caller that runs without the load-time guards (the unit tests, and any future
# non-launcher consumer).
claude_vm_effective_marketplaces() {
  local bake_doc="$1" boot_doc="$2" f seen="" mp_tab record name url
  mp_tab=$'\t'
  for f in "$bake_doc" "$boot_doc"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    while IFS= read -r record; do
      name=${record%%$mp_tab*}
      url=${record#*$mp_tab}
      [ -n "$name" ] || continue
      case " $seen " in
        *" $name "*) continue ;;
      esac
      seen="$seen $name"
      printf '%s\t%s\n' "$name" "$url"
    done < <(claude_vm_marketplaces "$f")
  done
}

# Emit the marketplace NAMES declared in the merged BAKE document, one per
# line, de-duplicated. This is the set the image is GUARANTEED to carry: a
# bake-declared marketplace that fails to register aborts the build, while a
# boot-declared one is only pre-registered best-effort (see the ORIGIN MARKER
# note on claude_vm_bake_plugins_json below, issue #226).
#
# Its callers are host-side: claude_vm_boot_marketplace_egress_needed, where a
# boot-declared name outside this set may still need an add at boot and so
# derives marketplace egress; and claude_vm_bake_plugins_json, which stamps
# each manifest entry's `origin` from it. The guest's own boot path does NOT
# read this set -- build-guest-image.sh's plugin_marketplace_registered asks
# the CLI what is actually registered, which is what lets it pick up a
# boot-declared marketplace the build could not pre-register.
#   $1 -- merged BAKE document file path
claude_vm_baked_marketplace_names() {
  local bake_doc="$1"
  [ -n "$bake_doc" ] && [ -f "$bake_doc" ] || return 0
  yq eval '.claude.marketplaces // [] | .[] | .name // ""' "$bake_doc" 2>/dev/null \
    | grep -v '^$' | sort -u
}

# Emit the hostnames parsed out of both documents' claude.marketplaces urls,
# one per line, de-duplicated. Used to derive the egress hosts a boot-side
# marketplace add/update/install needs.
#
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
#
# Parsing is the SAME permissive extraction claude_vm_apt_source_hosts uses:
# find an http(s):// URI, strip the scheme, drop any userinfo@ prefix, then
# drop a :port suffix (allowlists here are host-only). A source with NO
# parseable http(s) URI -- notably `claude plugin marketplace add`'s
# `owner/repo` GitHub shorthand, or a local path -- contributes NOTHING rather
# than aborting, matching this file's "missing input -> empty, not an error"
# convention. That shorthand resolves to github.com, which the example egress
# allowlist already carries; the example configs document the pairing so an
# operator using the shorthand knows to keep github.com allowlisted.
claude_vm_marketplace_hosts() {
  local bake_doc="$1" boot_doc="$2" f
  for f in "$bake_doc" "$boot_doc"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    yq eval '.claude.marketplaces // [] | .[] | .url // ""' "$f" 2>/dev/null
  done \
    | grep -oE 'https?://[^/[:space:]]+' \
    | sed -E 's#^https?://##; s/^[^@]*@//; s/:.*$//' \
    | sort -u
}

# Emit the NAME of every effective marketplace whose url yields NO derivable
# egress host -- i.e. is not an http(s) URI (the `owner/repo` GitHub shorthand,
# a local path, or an empty url). The launcher warns about exactly these, so the
# operator knows which entry needs github.com kept in egress.allow by hand.
#
# Counted PER ENTRY rather than by comparing marketplace-count against
# host-count: several marketplaces routinely share one host (two github.com
# urls derive one `github.com`), so a count comparison would flag a perfectly
# well-formed config.
#
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
claude_vm_marketplaces_without_host() {
  local bake_doc="$1" boot_doc="$2" mp_tab record name url
  mp_tab=$'\t'
  # Hand split, per the TSV RECORDS note above.
  while IFS= read -r record; do
    name=${record%%$mp_tab*}
    url=${record#*$mp_tab}
    [ -n "$name" ] || continue
    case "$url" in
      http://*|https://*) ;;
      *) printf '%s\n' "$name" ;;
    esac
  done < <(claude_vm_effective_marketplaces "$bake_doc" "$boot_doc")
}

# True (exit 0) when a BOOT-SIDE marketplace ensure/install/update will run and
# therefore needs the marketplace hosts reachable from the guest. False means
# "auto, and nothing boot-side to do" -- the hard-secure config (everything
# bake-declared, updates off, `auto`) derives NOTHING and still has working
# plugins, because the baked ones need no marketplace at all.
#
#   $1 -- merged BOOT document file path
#   $2 -- merged BAKE document file path
#
# True iff ANY of:
#   - claude.plugins.add_marketplace_uris_to_allowlist is "always"
#   - claude.plugins.install_at_boot is nonempty      (a boot-side install)
#   - a marketplace is configured in the BOOT doc that is NOT bake-declared
#     (the build pre-registers those best-effort only, so the boot path may
#     still have to ADD it before anything can resolve against it)
#   - claude.plugins.update_at_boot is true AND at least one marketplace is
#     configured anywhere (with no marketplaces there is nothing to update, so
#     the default-true knob must not allowlist hosts for a config that has none)
claude_vm_boot_marketplace_egress_needed() {
  local boot_doc="$1" bake_doc="$2"
  local mode
  mode="$(claude_vm_scalar "$boot_doc" '.claude.plugins.add_marketplace_uris_to_allowlist' \
            "$CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_ADD_MARKETPLACE_URIS_TO_ALLOWLIST")"
  if [ "$mode" = "always" ]; then
    return 0
  fi
  if [ -n "$(claude_vm_list_items "$boot_doc" '.claude.plugins.install_at_boot')" ]; then
    return 0
  fi
  # The build pre-registers a boot-declared marketplace best-effort only
  # (issue #226), so one outside the bake-declared set may still need adding
  # at boot, which is itself marketplace egress.
  local baked_names mp_tab record name
  mp_tab=$'\t'
  baked_names="$(claude_vm_baked_marketplace_names "$bake_doc")"
  # Hand split, per the TSV RECORDS note above. Only the name is used here, but
  # the split still has to be total: a tab-IFS read strips a LEADING empty
  # field, so an entry with a url and no name handed this loop the URL as its
  # name, and the membership test below then compared a URL against a set of
  # NAMES -- deriving marketplace egress from a comparison that cannot match.
  while IFS= read -r record; do
    name=${record%%$mp_tab*}
    [ -n "$name" ] || continue
    case "
$baked_names
" in
      *"
$name
"*) ;;
      *) return 0 ;;
    esac
  done < <(claude_vm_marketplaces "$boot_doc")
  local update_at_boot
  update_at_boot="$(claude_vm_bool_scalar "$boot_doc" '.claude.plugins.update_at_boot' \
                     "$CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_UPDATE_AT_BOOT")"
  [ "$update_at_boot" = "true" ] \
    && [ -n "$(claude_vm_effective_marketplaces "$bake_doc" "$boot_doc")" ]
}

# Emit the CANONICAL bake-plugin manifest as compact JSON on stdout: the
# marketplaces the image build registers -- some as a hard requirement, some
# best-effort, see the ORIGIN MARKER note below -- and the plugin refs it must
# install. This is what the launcher hands build-guest-image.sh (and it, the
# provisioner) as build CONTENT -- the sibling of claude_vm_bake_config_json
# for packages/apt_sources.
#
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
#
# `marketplaces` is the EFFECTIVE set (bake ++ boot, deduped by name): the
# build tries to register every configured marketplace, not only the
# bake-declared ones, so a boot-side install usually finds its marketplace
# already present and needs no network to add it. Only the marketplace
# REGISTRATION is baked that way -- a boot-only marketplace still contributes
# no plugin to the bake set, and, because it lives in a boot file, still never
# moves the image-identity hash.
# `bake` is claude.plugins.bake from the BAKE doc only, with null/empty entries
# stripped (same hazard as a stray `-` in a package list) and sorted for a
# stable canonical form.
#
# ORIGIN MARKER (issue #226). Every marketplace entry carries `origin`, either
# `bake` (the name is declared in the BAKE doc) or `boot` (it reached the
# effective set from a BOOT file only). It exists because the two origins have
# DIFFERENT build-time failure policies, and the flat set the provisioner used
# to receive could not tell them apart:
#
#   bake -- registering it is a build PRECONDITION. The image is cached under
#           an identity hash that covers the bake files, so an image missing a
#           bake-declared marketplace would be reused by every later launch.
#           A failed add aborts the build.
#   boot -- registering it here is an OPTIMIZATION, never a precondition. Its
#           url only has to be reachable from the GUEST: a guest-local path
#           (`/mnt/repo`), a private source needing host-only credentials, or
#           an https host outside the build container's egress are all legal
#           and simply cannot be added at build time. A failed add warns and
#           continues, leaving the registration to the guest boot launcher's
#           boot_plugin_phase, which already adds any marketplace the image
#           does not carry.
#
# NOTE ON IDENTITY: this JSON is build CONTENT, not the cache key. Since #179
# the cache key is the whole-file raw-byte hash of the BAKE FILES, which
# already covers claude.marketplaces + claude.plugins.bake now that they live
# there -- that IS the "extend the bake-hash with marketplace/plugin refs" the
# issue asks for, achieved by placement instead of by a new key-picked hash.
# A boot-file-only marketplace deliberately does NOT rebuild the image, and
# (per the origin marker above) never fails one either; its registration is
# added at boot whenever the build could not pre-register it.
claude_vm_bake_plugins_json() {
  local bake_doc="$1" boot_doc="$2" mps mp_tab record name url origin baked_names first=1
  mps=""
  mp_tab=$'\t'
  # Membership test against the BAKE doc's own names decides each entry's
  # origin. Same newline-delimited idiom claude_vm_boot_marketplace_egress_needed
  # uses, so a name is compared whole rather than as a substring.
  baked_names="$(claude_vm_baked_marketplace_names "$bake_doc")"
  # Hand split, per the TSV RECORDS note above.
  while IFS= read -r record; do
    name=${record%%$mp_tab*}
    url=${record#*$mp_tab}
    [ -n "$name" ] || continue
    origin="boot"
    case "
$baked_names
" in
      *"
$name
"*) origin="bake" ;;
    esac
    if [ "$first" -eq 1 ]; then first=0; else mps="${mps},"; fi
    mps="${mps}$(CLAUDE_VM_MP_NAME="$name" CLAUDE_VM_MP_URL="$url" CLAUDE_VM_MP_ORIGIN="$origin" \
      yq eval -o=json -I=0 -n '
      {
        "name": strenv(CLAUDE_VM_MP_NAME),
        "url": strenv(CLAUDE_VM_MP_URL),
        "origin": strenv(CLAUDE_VM_MP_ORIGIN)
      }
    ' 2>/dev/null)"
  done < <(claude_vm_effective_marketplaces "$bake_doc" "$boot_doc")
  CLAUDE_VM_MPS="[${mps}]" yq eval -o=json -I=0 '
    {
      "marketplaces": (strenv(CLAUDE_VM_MPS) | from_yaml),
      "bake": (.claude.plugins.bake // [] | map(select(. != null and . != "")) | unique | sort)
    }
  ' "$bake_doc" 2>/dev/null
}

# ---------------------------------------------------------------------
# Guest Claude settings.json render (issue #104).
#
# Render the guest's ~/.claude/settings.json (installed at
# /root/.claude/settings.json by the guest boot launcher) from the merged
# config -- PURE (merged-config files in -> settings.json on stdout), so it
# is host-side unit-testable with no VM, no network, and no host mutation.
#
#   $1 -- merged BOOT document file path
#   $2 -- merged BAKE document file path (optional; omitted/missing means no
#         baked plugin refs, which is exactly the pre-#107 behavior)
#
# TWO documents since issue #107 moved claude.plugins.bake into the BAKE file
# (see the placement note above claude_vm_check_plugin_key_placement). Every
# other key this render reads -- permissions, permission_mode,
# plugins.install_at_boot, plugins.enabled -- is a BOOT key and still comes
# from the boot document.
#
# The rendered document's top-level keys are:
#
#   permissions:
#     allow | ask | deny  -- verbatim from merged claude.permissions.*
#                            (claude-vm configs ONLY; the host's
#                            ~/.claude/settings.json is NEVER consulted --
#                            the guest's PERMISSION surface is defined by the
#                            claude-vm configs, per the issue's product
#                            intent; the host's working-rules layer, issue
#                            #108, is separate and is copied in). An
#                            empty/unset list renders as [].
#     defaultMode         -- from claude.permission_mode (default
#                            bypassPermissions). Read here from the merged
#                            file with the same default so the render is
#                            self-contained and testable. The launcher
#                            (claude-vm.sh) enum-guards this value BEFORE
#                            calling here; this render trusts it.
#   enabledPlugins:
#     an object mapping every plugin ref in
#     (claude.plugins.bake ++ claude.plugins.install_at_boot) to a boolean.
#     Every such ref defaults to true (installed-and-enabled), de-duplicated
#     (bake first, then install_at_boot; a ref in both collapses to one
#     entry). The optional claude.plugins.enabled map -- which mirrors
#     settings.json's own enabledPlugins vocabulary (plugin ref -> boolean) --
#     then OVERRIDES those defaults per key: `false` marks a plugin
#     installed-but-disabled (re-enabling needs no reinstall -- the owner
#     toggles debug plugins like show-loaded-rules / show-loaded-skills
#     around specific issues), `true` is redundant with the default but
#     accepted.
#   extraKnownMarketplaces:
#     an object mapping every configured marketplace name (the EFFECTIVE set,
#     bake ++ boot) to its source, in the shape claude itself writes.
#
#     WHY THIS KEY IS HERE (issue #107, established by observation, not by
#     guesswork). Running `claude plugin install` was observed writing BOTH
#     `enabledPlugins` AND `extraKnownMarketplaces` into ~/.claude/settings.json
#     -- so the marketplace declaration lives in settings.json, alongside the
#     separate on-disk registry (~/.claude/plugins/known_marketplaces.json).
#     The guest's settings.json is a full host-side RENDER that the boot
#     launcher copies over whatever the image baked; without this key that copy
#     would DROP the extraKnownMarketplaces the bake step's own CLI run wrote,
#     leaving the guest's settings.json declaring plugins whose marketplaces it
#     never mentions. Rendering it from config keeps the file self-consistent
#     and, being derived from the same effective set the bake/boot paths use,
#     cannot drift from them.
#
#     Source shape is chosen per entry from the configured url, matching what
#     the CLI writes for each kind of source: an http(s) url renders as
#     {"source":"git","url":...}; a bare `owner/repo` shorthand renders as
#     {"source":"github","repo":...}. An entry with no url is skipped -- there
#     is nothing to declare.
#
#     NOTE this key does NOT make claude self-install a missing plugin. Tested
#     directly (issue #107's "settle in-slice" question): a home dir carrying
#     ONLY a settings.json with extraKnownMarketplaces + enabledPlugins and no
#     ~/.claude/plugins tree left `claude plugin marketplace list` reporting
#     "No marketplaces configured" and installed nothing. So the boot path does
#     NOT collapse into this render -- the explicit ensure/install/update phase
#     in the guest boot launcher is load-bearing.
#
# VALIDATION (done here, once, on the merged config -- this is the single
# reader/render path): every claude.plugins.enabled VALUE must be a boolean,
# and every KEY must name a plugin ref present in the merged
# (bake ++ install_at_boot) lists. A non-boolean value or an unknown key is
# a config typo and ABORTS (non-zero return + a claude-vm: diagnostic on
# stderr) so the launcher stops rather than rendering a settings.json that
# silently drops or misspells a plugin toggle.
claude_vm_render_guest_settings() {
  local file="$1" bake_doc="${2:-}"
  local permission_mode

  # Resolve permission_mode with the same default as the schema
  # (bypassPermissions). claude_vm_scalar treats absent/null as the
  # fallback; permission_mode is a plain string, never a boolean, so the
  # non-boolean-safe accessor is correct here. The launcher enum-guards the
  # value up front, so an unexpected mode never reaches this render.
  permission_mode="$(claude_vm_scalar "$file" '.claude.permission_mode' "$CLAUDE_VM_DEFAULT_CLAUDE_PERMISSION_MODE")"

  # Collect the installed plugin refs (bake ++ install_at_boot), preserving
  # order and de-duplicating. These are both the enabledPlugins keys (all
  # default true) AND the valid key-set for claude.plugins.enabled overrides.
  local ref installed=() seen=""
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case " $seen " in
      *" $ref "*) continue ;;
    esac
    seen="$seen $ref"
    installed+=("$ref")
  done < <(
    # Baked refs come from the BAKE document (issue #107 placement); a missing
    # bake doc simply contributes none.
    if [ -n "$bake_doc" ] && [ -f "$bake_doc" ]; then
      claude_vm_list_items "$bake_doc" '.claude.plugins.bake'
    fi
    claude_vm_list_items "$file" '.claude.plugins.install_at_boot'
  )

  # Read the claude.plugins.enabled override map as tab-separated
  # "ref<TAB>value" lines. yq emits nothing when the key is absent.
  # Validate each entry HERE, once: key must be non-empty and must name an
  # installed ref, value must be a boolean. Build an override map keyed by ref.
  #
  # Records are split by hand, per the TSV RECORDS note near the top of this
  # file. An empty KEY (`enabled: { "": true }`) leads the record with an empty
  # field, and a tab-IFS read strips it: this loop used to see ov_ref=true /
  # ov_val="" and abort with a message blaming a plugin called `true`. It now
  # sees the empty ref and says so. That entry ABORTS rather than being skipped
  # -- an override no plugin can ever match is a typo, and this render is the
  # single place claude.plugins.enabled is validated.
  #
  # The map is TWO PARALLEL INDEXED ARRAYS, not an associative array, because
  # this render is launcher-reachable and stock macOS /bin/bash is 3.2, which
  # has no associative arrays -- see payload/README.md -> *A guard must survive
  # the oldest bash that can reach it*. `local -A` there is a hard
  # `local: -A: invalid option`, and the `map["$ov_ref"]=` assignment that
  # followed it is worse: 3.2 evaluates an indexed array's subscript
  # ARITHMETICALLY, so a real ref like `block-background-agents@thevoskamps`
  # parses as an expression whose leading identifier `block` is unbound, and
  # `set -u` kills the launch after the image build. Every config carrying a
  # claude.plugins.enabled override whose ref LEADS WITH AN IDENTIFIER hit
  # that -- which is every real plugin ref; a digits-only ref is valid
  # arithmetic and survives, writing the wrong slot instead (measured on
  # 3.2.57). A config with no override never entered this branch at all, which
  # is why the defect survived to a real launch.
  local ov_refs=() ov_vals=()
  local ov_tab ov_record ov_ref ov_val ov_idx=0
  ov_tab=$'\t'
  while IFS= read -r ov_record; do
    # An ABSENT enabled map is one empty line, not zero bytes (yq prints a
    # newline for `{} | to_entries | .[]`). Skip it before the empty-ref abort
    # below, which would otherwise fire on every config that sets no overrides.
    [ -n "$ov_record" ] || continue
    ov_idx=$((ov_idx + 1))
    ov_ref=${ov_record%%$ov_tab*}
    ov_val=${ov_record#*$ov_tab}
    if [ -z "$ov_ref" ]; then
      echo "claude-vm: claude.plugins.enabled entry #${ov_idx} has an empty plugin ref (value: '$ov_val')" >&2
      echo "claude-vm:   every key must name a plugin ref from claude.plugins.bake or install_at_boot" >&2
      return 1
    fi
    case "$ov_val" in
      true|false) : ;;
      *)
        echo "claude-vm: claude.plugins.enabled['$ov_ref'] must be a boolean (true|false), got '$ov_val'" >&2
        return 1 ;;
    esac
    case " $seen " in
      *" $ov_ref "*) : ;;
      *)
        echo "claude-vm: claude.plugins.enabled['$ov_ref'] names a plugin not in claude.plugins.bake or install_at_boot" >&2
        return 1 ;;
    esac
    # Append rather than assign-by-key. A repeated ref therefore appears
    # twice; the lookup below scans to the END and keeps the LAST match, which
    # is the same value an associative-array assignment would have left.
    ov_refs+=("$ov_ref")
    ov_vals+=("$ov_val")
  done < <(
    yq eval '
      .claude.plugins.enabled // {}
      | to_entries | .[] | [.key, .value] | @tsv
    ' "$file" 2>/dev/null
  )

  # Build the enabledPlugins object as a YAML fragment: every installed ref
  # -> true, then apply the validated overrides.
  local plugins_yaml="" value ov_i ov_n
  ov_n=${#ov_refs[@]}
  for ref in ${installed[@]+"${installed[@]}"}; do
    value="true"
    # Linear last-wins lookup over the parallel override arrays (see the
    # bash-3.2 note above). The scan does not break at the first hit, so a ref
    # recorded twice resolves to its last recorded value.
    ov_i=0
    while [ "$ov_i" -lt "$ov_n" ]; do
      if [ "${ov_refs[$ov_i]}" = "$ref" ]; then
        value="${ov_vals[$ov_i]}"
      fi
      ov_i=$((ov_i + 1))
    done
    # Quote the key so a ref containing YAML-significant characters is a
    # valid single mapping key; the value is a bare boolean literal.
    plugins_yaml="${plugins_yaml}$(printf '%s' "$ref" | yq -o=json eval '.' - 2>/dev/null): ${value}"$'\n'
  done

  # An empty fragment (no plugin refs at all) must parse to an empty object,
  # not the empty string -- `"" | from_yaml` errors with EOF in yq. Default
  # it to the literal `{}` so enabledPlugins renders as {} when no plugins
  # are configured.
  [ -n "$plugins_yaml" ] || plugins_yaml="{}"

  # Build the extraKnownMarketplaces object (issue #107) over the EFFECTIVE
  # marketplace set -- the same bake ++ boot union the bake step and the guest
  # boot phase use, so the three can never disagree about which marketplaces
  # the guest knows. Per-entry source shape is chosen from the url, matching
  # what claude itself writes: an http(s) url -> {"source":"git","url":...};
  # anything else is treated as the `owner/repo` GitHub shorthand ->
  # {"source":"github","repo":...}. A urlless entry contributes nothing.
  local mp_yaml="" mp_tab mp_record mp_name mp_url mp_src
  mp_tab=$'\t'
  # Hand split, per the TSV RECORDS note near the top of this file.
  while IFS= read -r mp_record; do
    mp_name=${mp_record%%$mp_tab*}
    mp_url=${mp_record#*$mp_tab}
    [ -n "$mp_name" ] && [ -n "$mp_url" ] || continue
    case "$mp_url" in
      http://*|https://*)
        mp_src="$(CLAUDE_VM_MP_URL="$mp_url" yq eval -o=json -I=0 -n \
          '{"source": "git", "url": strenv(CLAUDE_VM_MP_URL)}' 2>/dev/null)" ;;
      *)
        mp_src="$(CLAUDE_VM_MP_URL="$mp_url" yq eval -o=json -I=0 -n \
          '{"source": "github", "repo": strenv(CLAUDE_VM_MP_URL)}' 2>/dev/null)" ;;
    esac
    mp_yaml="${mp_yaml}$(printf '%s' "$mp_name" | yq -o=json eval '.' - 2>/dev/null): {\"source\": ${mp_src}}"$'\n'
  done < <(claude_vm_effective_marketplaces "$bake_doc" "$file")
  # Same empty-fragment guard as enabledPlugins above: `"" | from_yaml` errors.
  [ -n "$mp_yaml" ] || mp_yaml="{}"

  # Compose the final document: permissions.{allow,ask,deny} verbatim from
  # the merged config (// [] so an unset list renders as []), the resolved
  # defaultMode, and the enabledPlugins / extraKnownMarketplaces fragments
  # injected as parsed YAML.
  CLAUDE_VM_PERMISSION_MODE="$permission_mode" \
  CLAUDE_VM_ENABLED_PLUGINS="$plugins_yaml" \
  CLAUDE_VM_EXTRA_MARKETPLACES="$mp_yaml" \
    yq eval -o=json '
      {
        "permissions": {
          "allow": (.claude.permissions.allow // []),
          "ask":   (.claude.permissions.ask   // []),
          "deny":  (.claude.permissions.deny  // []),
          "defaultMode": strenv(CLAUDE_VM_PERMISSION_MODE)
        },
        "enabledPlugins": (strenv(CLAUDE_VM_ENABLED_PLUGINS) | from_yaml // {}),
        "extraKnownMarketplaces": (strenv(CLAUDE_VM_EXTRA_MARKETPLACES) | from_yaml // {})
      }
    ' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------
# CLAUDE_ARGS shell-quoting round-trip (issue #88).
#
# The launcher passes the user's post-repo CLI args ("$@") into the guest
# via a single CLAUDE_ARGS= line in run.env, which the guest boot launcher
# reconstructs into argv. A flat unquoted join breaks the instant any arg
# contains whitespace, a shell metacharacter, or a `#` (comment) -- e.g.
# `--name "foo #7 micro-vm Claude Plugins"` sourced as an unquoted line
# tries to EXECUTE `--name` (with the `#...` stripped as a comment) and the
# getty login program dies. Pre-#179 that respawned forever; since #179's
# `Restart=no` it just ends the session -- either way the boot is broken, which
# is what this quoting prevents.
#
# The contract, in TWO halves that must stay in lockstep:
#
#   HOST write (claude-vm.sh):
#     printf 'CLAUDE_ARGS=%q\n' "$(claude_vm_quote_args "${CLAUDE_ARGS[@]}")"
#   The inner per-arg %q (this helper) preserves each arg's boundaries; the
#   outer %q makes the whole CLAUDE_ARGS=<...> line safe to `source` under
#   `set -a`, so the sourced value is EXACTLY the space-separated
#   per-arg-%q string with no re-splitting or comment-stripping.
#
#   GUEST read (build-guest-image.sh boot launcher):
#     eval "set -- ${CLAUDE_ARGS:-}"
#     "$CLAUDE_BIN" "$@"
#   `eval set --` re-parses the per-arg-%q tokens back into the original
#   argv, exactly reversing this helper.
#
# This function prints each argument %q-quoted, space-separated, and prints
# a trailing newline. CRITICAL: ZERO args must print NOTHING (empty output).
# `printf '%q ' "${arr[@]}"` on an EMPTY array under `set -u` still emits a
# single `''` -- one bogus empty argument that would round-trip into an
# unwanted empty argv element downstream. So the empty case is guarded
# explicitly and returns before any printf over the array.
claude_vm_quote_args() {
  # No args -> empty output (NOT a stray ''). Guard the array expansion.
  if [ "$#" -eq 0 ]; then
    printf '\n'
    return 0
  fi
  local out="" arg
  for arg in "$@"; do
    if [ -z "$out" ]; then
      printf -v out '%q' "$arg"
    else
      printf -v out '%s %q' "$out" "$arg"
    fi
  done
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------
# Remote Control args augmentation (issue #88).
#
# Given the user's post-repo CLI args, apply two OPT-IN augmentations and
# print the resulting argv, one arg per line (NUL-free, newline-delimited)
# so the caller can read it back into an array with `mapfile`/a read loop
# without re-splitting on spaces inside an arg.
#
#   $1  -- rc_enabled: "true" to enable Remote Control injection, anything
#          else to leave RC alone (the config knob claude.remote_control,
#          resolved by the caller; false/unset -> no injection).
#   $2  -- name_stamp: the value to use for a defaulted `--name` (the caller
#          passes a `date '+%b%d-%H:%M'` stamp). Passed IN (not computed here)
#          so this function stays pure and unit-testable with a fixed stamp.
#   $3.. -- the user's CLI args (may be empty).
#
# Augmentation rules:
#   1. Remote Control injection: when rc_enabled=true AND the args do NOT
#      already contain `--remote-control`, prepend `--remote-control`. When
#      the user already passed it (via CLI), do NOT duplicate it.
#   2. --name date-stamp default: AFTER (1), if the effective args contain
#      `--remote-control` but NO `--name` (checking BOTH the `--name <v>` and
#      `--name=<v>` forms), append `--name <name_stamp>`. This applies whether
#      RC came from the knob or from an explicit CLI `--remote-control`, and it
#      never overrides a user-provided `--name`.
#
# With rc_enabled != true AND no `--remote-control` in the args, the args are
# passed through UNCHANGED (plain CLI pass-through still works).
claude_vm_augment_rc_args() {
  local rc_enabled="$1" name_stamp="$2"
  shift 2

  # Collect the incoming args into an array (may be empty).
  local -a args=()
  if [ "$#" -gt 0 ]; then
    args=("$@")
  fi

  # (1) Inject --remote-control when the knob is on and it is not already
  #     present. Prepend so it leads the argv, mirroring how a user would
  #     type it first.
  local a has_rc=0
  for a in ${args[@]+"${args[@]}"}; do
    if [ "$a" = "--remote-control" ]; then
      has_rc=1
      break
    fi
  done
  if [ "$rc_enabled" = "true" ] && [ "$has_rc" -eq 0 ]; then
    args=(--remote-control ${args[@]+"${args[@]}"})
    has_rc=1
  fi

  # (2) Default --name to the date stamp when RC is in effect but the user
  #     gave no --name (in either the `--name value` or `--name=value` form).
  if [ "$has_rc" -eq 1 ]; then
    local has_name=0
    for a in ${args[@]+"${args[@]}"}; do
      case "$a" in
        --name|--name=*) has_name=1; break ;;
      esac
    done
    if [ "$has_name" -eq 0 ]; then
      args=(${args[@]+"${args[@]}"} --name "$name_stamp")
    fi
  fi

  # Emit one arg per line so the caller reconstructs argv without re-splitting.
  local out
  for out in ${args[@]+"${args[@]}"}; do
    printf '%s\n' "$out"
  done
}
