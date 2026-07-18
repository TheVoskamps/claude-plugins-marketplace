#!/usr/bin/env bash
#
# config.sh -- two-tier YAML config loader + layering for claude-vm.
#
# Sourced by claude-vm.sh. Also directly testable: the layering logic
# is pure (two input files -> one merged YAML on stdout) with no VM,
# no network, and no host mutation, so payload/test/config-test.sh
# exercises it in isolation.
#
# Layering semantics (from issue #6, extended by issue #103):
#   - Scalars (cpus, mem, guest_image, repo.mount, repo.copy_back,
#     proxy.cmd, proxy.port, proxy.host_alias, packages.update_at_boot,
#     packages.add_apt_uris_to_allowlist, claude.permission_mode,
#     claude.plugins.update_at_boot,
#     claude.plugins.add_marketplace_uris_to_allowlist,
#     github.auth): repo overrides global; global fills gaps.
#   - Scalar MAPS (claude.plugins.enabled): repo-over-global PER KEY -- each
#     plugin-ref -> boolean entry follows the scalar repo-wins rule
#     independently, so a repo can flip one plugin's enabled state without
#     restating the global map. See claude_vm_merge_config below.
#   - Lists (egress.allow, mounts, packages.bake, packages.install_at_boot,
#     packages.apt_sources, claude.permissions.allow/ask/deny,
#     claude.marketplaces, claude.plugins.bake,
#     claude.plugins.install_at_boot -- see CLAUDE_VM_LIST_KEYS below):
#     MERGED -- union of global + repo entries (de-duplicated, order:
#     global entries first, then repo entries not already present).
#
# Both layers are OPTIONAL. A missing file is treated as `{}` (empty
# document), so any combination of {neither, global-only, repo-only,
# both} resolves cleanly.
#
# Secrets are never read from or written to these files. The guest
# authenticates with the host's claude.ai OAuth credential, which the
# launcher extracts from the macOS Keychain at launch; see SKILL.md.
#
# Requires: yq (v4+, the Go/mikefarah implementation). Detected at
# source time so callers fail fast with an actionable message.

set -uo pipefail

# Default config locations. Overridable via env for testing.
: "${CLAUDE_VM_GLOBAL_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/config.yml}"
# CLAUDE_VM_REPO_CONFIG is resolved per-run relative to the repo root
# by the launcher (<repo>/.claude-vm/config.yml); tests set it directly.

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
# payload/config.example.yml and skills/claude-vm/SKILL.md for the full
# annotated schema and semantics.
CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT=true
CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST=auto
CLAUDE_VM_DEFAULT_CLAUDE_PERMISSION_MODE=bypassPermissions
CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_UPDATE_AT_BOOT=true
CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_ADD_MARKETPLACE_URIS_TO_ALLOWLIST=auto
CLAUDE_VM_DEFAULT_GITHUB_AUTH=none

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
  '.packages.bake'
  '.packages.install_at_boot'
  '.packages.apt_sources'
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
# those (packages.update_at_boot, claude.plugins.update_at_boot).
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
#   $2 -- yq path expression (e.g. '.packages.update_at_boot')
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
#   $2 -- yq path expression to the list (e.g. '.packages.bake')
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
    .packages.apt_sources // [] | .[]
    | [(.name // ""), (.repo // ""), (.key_url // "")] | @tsv
  ' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------
# Boot-time apt derived egress (issue #106).
#
# packages.install_at_boot / packages.update_at_boot install/refresh apt
# packages at guest boot, through the proxy -- so the Debian mirror hosts
# (and any packages.apt_sources hosts) must be reachable from the guest.
# The launcher adds them to the egress allowlist iff boot-time apt work is
# actually configured (packages.add_apt_uris_to_allowlist: auto, the
# default) or unconditionally when the operator opts in
# (packages.add_apt_uris_to_allowlist: always). See
# claude_vm_boot_apt_egress_needed (the "iff" gate) and
# claude_vm_apt_source_hosts (the per-entry host derivation) below.

# The two Debian mirror hosts every install_at_boot/update_at_boot needs
# regardless of packages.apt_sources -- the base image's /etc/apt/sources.list
# points at these.
CLAUDE_VM_DEBIAN_MIRROR_HOSTS="deb.debian.org security.debian.org"

# True (exit 0) when boot-time apt work is configured that needs the Debian
# mirrors/apt_sources hosts reachable from the guest -- i.e. the launcher
# should derive and add apt egress to the allowlist. False (exit 1) means
# "auto, and nothing configured" -- a hard-secure all-baked config leaves
# package repos unreachable from the guest by design.
#
#   $1 -- merged config file path
#
# True iff ANY of:
#   - packages.install_at_boot is nonempty
#   - packages.update_at_boot is true (default true)
#   - packages.add_apt_uris_to_allowlist is "always" (default "auto")
claude_vm_boot_apt_egress_needed() {
  local file="$1"
  local mode
  mode="$(claude_vm_scalar "$file" '.packages.add_apt_uris_to_allowlist' "$CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST")"
  if [ "$mode" = "always" ]; then
    return 0
  fi
  if [ -n "$(claude_vm_list_items "$file" '.packages.install_at_boot')" ]; then
    return 0
  fi
  local update_at_boot
  update_at_boot="$(claude_vm_bool_scalar "$file" '.packages.update_at_boot' "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT")"
  [ "$update_at_boot" = "true" ]
}

# Emit the hostnames parsed out of packages.apt_sources repo/key_url URIs,
# one per line, de-duplicated. Used (alongside CLAUDE_VM_DEBIAN_MIRROR_HOSTS)
# to derive the egress hosts a boot-time apt_sources render needs.
#
#   $1 -- merged config file path
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
  local file="$1"
  # Emit repo/key_url as a flat YAML LIST (not a bare comma-expression) so an
  # entry with no key_url still contributes its "" placeholder line rather
  # than silently dropping the NEXT entry's key_url -- a comma-expression
  # (`(.repo // ""), (.key_url // "")` per .[] element) was observed to
  # collapse output across array elements under yq v4.53 when an element
  # produced an empty second branch.
  yq eval '
    .packages.apt_sources // [] | .[]
    | [(.repo // ""), (.key_url // "")] | .[]
  ' "$file" 2>/dev/null \
    | grep -oE 'https?://[^/[:space:]]+' \
    | sed -E 's#^https?://##; s/^[^@]*@//; s/:.*$//' \
    | sort -u
}

# ---------------------------------------------------------------------
# Bake-relevant config canonicalization + bake-hash (issue #105).
#
# The guest image bakes packages.bake into the mkosi Packages= list and
# renders packages.apt_sources into the build (keyring + sources.list.d).
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
#   - packages.bake       -> the list, with null/empty-string entries STRIPPED
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
#   - packages.apt_sources-> each entry reduced to exactly {name, repo,
#                            key_url} with a missing/null field normalized to
#                            "" (so a missing vs. explicit-empty key_url hash
#                            identically), then the whole list SORTED by name
#                            (so declaration order does not change the hash).
# Absent packages / packages.bake / packages.apt_sources all normalize to the
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
      "bake": (.packages.bake // [] | map(select(. != null and . != "")) | unique | sort),
      "apt_sources": (
        .packages.apt_sources // []
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
# The 8-hex prefix is the image-variant discriminator the launcher folds into
# the guest image's cache key + filename (guest-<hash>.raw). An empty bake
# config always yields the SAME hash (the canonical `{"bake":[],
# "apt_sources":[]}` is constant), so repos with no bake overrides collide on
# one hash and share one image -- exactly the intended warm-path behavior.
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
# both packages.bake and packages.apt_sources are empty/absent. The launcher
# uses this to decide between the shared default image (guest.raw) and a
# per-variant image (guest-<hash>.raw): an empty bake config shares the global
# image, a non-empty one gets its own cached variant.
#
#   $1 -- merged config file path
claude_vm_bake_config_is_empty() {
  local file="$1" count
  count="$(yq eval '
    ((.packages.bake // []) | length) + ((.packages.apt_sources // []) | length)
  ' "$file" 2>/dev/null)"
  [ "${count:-0}" = "0" ]
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
# Guest Claude settings.json render (issue #104).
#
# Render the guest's ~/.claude/settings.json (installed at
# /root/.claude/settings.json by the guest boot launcher) from the merged
# config -- PURE (merged-config file in -> settings.json on stdout), so it
# is host-side unit-testable with no VM, no network, and no host mutation.
#
#   $1 -- merged config file path
#
# The rendered document has exactly two top-level keys:
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
#
# VALIDATION (done here, once, on the merged config -- this is the single
# reader/render path): every claude.plugins.enabled VALUE must be a boolean,
# and every KEY must name a plugin ref present in the merged
# (bake ++ install_at_boot) lists. A non-boolean value or an unknown key is
# a config typo and ABORTS (non-zero return + a claude-vm: diagnostic on
# stderr) so the launcher stops rather than rendering a settings.json that
# silently drops or misspells a plugin toggle.
claude_vm_render_guest_settings() {
  local file="$1"
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
    claude_vm_list_items "$file" '.claude.plugins.bake'
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

  # Compose the final document: permissions.{allow,ask,deny} verbatim from
  # the merged config (// [] so an unset list renders as []), the resolved
  # defaultMode, and the enabledPlugins fragment injected as parsed YAML.
  CLAUDE_VM_PERMISSION_MODE="$permission_mode" \
  CLAUDE_VM_ENABLED_PLUGINS="$plugins_yaml" \
    yq eval -o=json '
      {
        "permissions": {
          "allow": (.claude.permissions.allow // []),
          "ask":   (.claude.permissions.ask   // []),
          "deny":  (.claude.permissions.deny  // []),
          "defaultMode": strenv(CLAUDE_VM_PERMISSION_MODE)
        },
        "enabledPlugins": (strenv(CLAUDE_VM_ENABLED_PLUGINS) | from_yaml // {})
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
# tries to EXECUTE `--name` (with the `#...` stripped as a comment), the
# getty login program dies, and agetty respawns it forever.
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
#     exec "$CLAUDE_BIN" "$@"
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
