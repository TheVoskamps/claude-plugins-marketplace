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
#   - Scalar MAPS (claude.plugins.enabled): repo-over-global PER KEY -- each
#     plugin-ref -> boolean entry follows the scalar repo-wins rule
#     independently, so a repo can flip one plugin's enabled state without
#     restating the global map. See claude_vm_merge_config below.
#   - Lists (egress.allow, mounts, packages, apt_sources,
#     claude.permissions.allow/ask/deny, claude.marketplaces,
#     claude.plugins.bake, claude.plugins.install_at_boot -- see
#     CLAUDE_VM_LIST_KEYS below): MERGED -- union of global + repo entries
#     (de-duplicated, order: global entries first, then repo entries not
#     already present).
#
# All four files are OPTIONAL. A missing file is treated as `{}` (empty
# document), so any combination resolves cleanly.
#
# Secrets are never read from or written to these files. The guest
# authenticates with the host's claude.ai OAuth credential, which the
# launcher extracts from the macOS Keychain at launch; see SKILL.md.
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

# Emit mounts as tab-separated "source<TAB>tag<TAB>mode" lines from a
# merged-config file. mode defaults to "ro" when unset on a mount entry.
claude_vm_mount_specs() {
  local file="$1"
  yq eval '
    .mounts // [] | .[]
    | [.source, .tag, (.mode // "ro")] | @tsv
  ' "$file" 2>/dev/null
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
# An absent `packages:` / `apt_sources:` both normalize to the
# empty list, so a config with no bake-affecting overrides emits exactly
# `{"bake":[],"apt_sources":[]}` -- a stable value shared across every such
# config (the "shares the global image" case). Output is compact (-I=0) and
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
# both the bake `packages:` and `apt_sources:` are empty/absent.
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

# Abort (non-zero + a claude-vm: diagnostic) when a claude.plugins sub-key
# appears in the file type that never reads it. Without this the key parses,
# merges, and is silently ignored -- e.g. `claude.plugins.bake` written into
# config-boot.yml would leave the operator with an image that bakes NO plugins
# and no indication why.
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
claude_vm_check_plugin_key_placement() {
  local bake_doc="$1" boot_doc="$2" key present bad=0
  for key in "${CLAUDE_VM_PLUGIN_BOOT_ONLY_KEYS[@]}"; do
    present="$(yq eval "(.claude.plugins.${key} != null)" "$bake_doc" 2>/dev/null)"
    if [ "$present" = "true" ]; then
      echo "claude-vm: 'claude.plugins.${key}' is a BOOT key but was found in a config-bake.yml." >&2
      echo "claude-vm:   move it to config-boot.yml -- the bake files only feed the image build," >&2
      echo "claude-vm:   so it would parse here and never be read." >&2
      bad=1
    fi
  done
  for key in "${CLAUDE_VM_PLUGIN_BAKE_ONLY_KEYS[@]}"; do
    present="$(yq eval "(.claude.plugins.${key} != null)" "$boot_doc" 2>/dev/null)"
    if [ "$present" = "true" ]; then
      echo "claude-vm: 'claude.plugins.${key}' is a BAKE key but was found in a config-boot.yml." >&2
      echo "claude-vm:   move it to config-bake.yml -- baked plugins change the guest image's bytes," >&2
      echo "claude-vm:   so they must live where the image-identity hash can see them." >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
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

# Emit the EFFECTIVE marketplace set as "name<TAB>url" lines: the union of both
# documents' claude.marketplaces, BAKE entries first, de-duplicated by NAME
# (conflicting urls under one name already aborted in
# claude_vm_check_marketplace_conflicts, so a later duplicate name here is
# byte-identical and safely dropped). Both the image build and the guest boot
# consume this same set, so a plugin ref resolves identically in either place.
#   $1 -- merged BAKE document file path
#   $2 -- merged BOOT document file path
claude_vm_effective_marketplaces() {
  local bake_doc="$1" boot_doc="$2" f seen="" name url
  for f in "$bake_doc" "$boot_doc"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    while IFS=$'\t' read -r name url; do
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
# line, de-duplicated. These are already registered inside the image, so the
# boot path only has to ADD the ones this set does not cover -- which is also
# what decides whether a boot-side marketplace add (and therefore marketplace
# egress) is needed at all.
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
  local bake_doc="$1" boot_doc="$2" name url
  while IFS=$'\t' read -r name url; do
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
# baked, updates off, `auto`) derives NOTHING and still has working plugins,
# because the baked ones are already inside the image.
#
#   $1 -- merged BOOT document file path
#   $2 -- merged BAKE document file path
#
# True iff ANY of:
#   - claude.plugins.add_marketplace_uris_to_allowlist is "always"
#   - claude.plugins.install_at_boot is nonempty      (a boot-side install)
#   - a marketplace is configured in the BOOT doc that is NOT already baked
#     (the boot path must ADD it before anything can resolve against it)
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
  # A boot-declared marketplace the image does not already carry must be added
  # at boot, which is itself marketplace egress.
  local baked_names name
  baked_names="$(claude_vm_baked_marketplace_names "$bake_doc")"
  while IFS=$'\t' read -r name _; do
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
# marketplaces the image build must register and the plugin refs it must
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
  local bake_doc="$1" boot_doc="$2" mps name url origin baked_names first=1
  mps=""
  # Membership test against the BAKE doc's own names decides each entry's
  # origin. Same newline-delimited idiom claude_vm_boot_marketplace_egress_needed
  # uses, so a name is compared whole rather than as a substring.
  baked_names="$(claude_vm_baked_marketplace_names "$bake_doc")"
  while IFS=$'\t' read -r name url; do
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
#                            the guest's Claude surface is defined by the
#                            claude-vm configs, per the issue's product
#                            intent). An empty/unset list renders as [].
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
  # Validate each entry HERE, once: value must be a boolean, key must be an
  # installed ref. Build an associative override map keyed by ref.
  local -A enabled_override=()
  local line ov_ref ov_val
  while IFS=$'\t' read -r ov_ref ov_val; do
    [ -n "$ov_ref" ] || continue
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
    enabled_override["$ov_ref"]="$ov_val"
  done < <(
    yq eval '
      .claude.plugins.enabled // {}
      | to_entries | .[] | [.key, .value] | @tsv
    ' "$file" 2>/dev/null
  )

  # Build the enabledPlugins object as a YAML fragment: every installed ref
  # -> true, then apply the validated overrides.
  local plugins_yaml="" value
  for ref in ${installed[@]+"${installed[@]}"}; do
    value="true"
    if [ -n "${enabled_override[$ref]+x}" ]; then
      value="${enabled_override[$ref]}"
    fi
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
  local mp_yaml="" mp_name mp_url mp_src
  while IFS=$'\t' read -r mp_name mp_url; do
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
