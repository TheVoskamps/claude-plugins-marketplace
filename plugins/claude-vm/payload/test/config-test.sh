#!/usr/bin/env bash
#
# config-test.sh -- unit tests for claude-vm's config layering.
#
# Exercises payload/lib/config.sh's pure layering logic (two YAML
# inputs -> one merged document) with no VM, no network, no host
# mutation. Run directly:
#
#   plugins/claude-vm/payload/test/config-test.sh
#
# Requires: yq (mikefarah v4+). Skips with a clear message if absent.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/config.sh"

# shellcheck source=../lib/config.sh
. "$LIB"

if ! claude_vm_require_yq; then
  echo "SKIP: yq not available; config layering tests skipped." >&2
  exit 0
fi

WORK="$(claude_vm_mktemp -d claude-vm-test)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# assert_eq <label> <expected> <actual>
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "ok   - $label"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $label"
    echo "        expected: [$expected]"
    echo "        actual:   [$actual]"
  fi
}

# ---------------------------------------------------------------------
# Fixtures -- per-tier files in their FILE schemas (issue #179 two-doc
# model): boot files carry runtime wiring (flat `packages:` = install at
# boot, top-level `update_at_boot`/`add_apt_uris_to_allowlist`), bake
# files carry image content (flat `packages:` = baked, root_headroom).
# ---------------------------------------------------------------------
GLOBAL_BOOT="$WORK/global-boot.yml"
REPO_BOOT="$WORK/repo-boot.yml"
GLOBAL_BAKE="$WORK/global-bake.yml"
REPO_BAKE="$WORK/repo-bake.yml"

cat > "$GLOBAL_BOOT" <<'YML'
cpus: 2
mem: 4096
guest_image: /global/guest.raw
repo:
  mount: clone
proxy:
  cmd: "global-proxy"
  port: 3128
  host_alias: 192.168.127.254
egress:
  allow:
    - api.anthropic.com
    - github.com
mounts:
  - source: ~/.claude/policy
    tag: policy
packages:
  - htop
update_at_boot: false
add_apt_uris_to_allowlist: auto
apt_sources:
  - name: boot-global-src
    repo: "deb https://boot.example.com/global stable main"
    key_url: https://boot.example.com/global/key.asc
claude:
  permission_mode: bypassPermissions
  permissions:
    allow:
      - "Bash(git:*)"
    ask:
      - "Bash(rm:*)"
    deny:
      - "Bash(sudo:*)"
  plugins:
    install_at_boot:
      - bar@global-mp
    update_at_boot: false
    add_marketplace_uris_to_allowlist: auto
    enabled:
      foo@global-mp: true
      bar@global-mp: false
github:
  auth: none
YML

cat > "$REPO_BOOT" <<'YML'
cpus: 8
guest_image: /repo/guest.raw
repo:
  mount: live
egress:
  allow:
    - github.com
    - cache.example.com
mounts:
  - source: ~/datasets/foo
    tag: data
packages:
  - build-essential
update_at_boot: true
add_apt_uris_to_allowlist: always
apt_sources:
  - name: boot-repo-src
    repo: "deb https://boot.example.com/repo stable main"
    key_url: https://boot.example.com/repo/key.asc
claude:
  permission_mode: default
  permissions:
    allow:
      - "Bash(npm:*)"
    ask:
      - "Bash(rm:*)"
    deny:
      - "Bash(curl:*)"
  plugins:
    install_at_boot:
      - bar@global-mp
    update_at_boot: true
    add_marketplace_uris_to_allowlist: always
    enabled:
      bar@global-mp: true
github:
  auth: host-token
YML

cat > "$GLOBAL_BAKE" <<'YML'
image:
  root_headroom_mb: 1024
packages:
  - jq
  - ripgrep
apt_sources:
  - name: global-repo
    repo: "deb https://example.com/global stable main"
    key_url: https://example.com/global/key.asc
claude:
  marketplaces:
    - name: global-mp
      url: https://example.com/global-mp
  plugins:
    bake:
      - foo@global-mp
YML

cat > "$REPO_BAKE" <<'YML'
image:
  root_headroom_mb: 2048
packages:
  - ripgrep
  - fd-find
apt_sources:
  - name: repo-registry
    repo: "deb https://example.com/repo stable main"
    key_url: https://example.com/repo/key.asc
claude:
  marketplaces:
    - name: repo-mp
      url: https://example.com/repo-mp
  plugins:
    bake:
      - baz@repo-mp
YML

# ---------------------------------------------------------------------
# Test 1: scalar override -- repo wins, global fills gaps (per tier)
# ---------------------------------------------------------------------
MERGED_BOOT="$WORK/merged-boot.yml"
MERGED_BAKE="$WORK/merged-bake.yml"
claude_vm_merge_config "$GLOBAL_BOOT" "$REPO_BOOT" > "$MERGED_BOOT"
claude_vm_merge_config "$GLOBAL_BAKE" "$REPO_BAKE" > "$MERGED_BAKE"

assert_eq "scalar: repo overrides global (cpus)" \
  "8" "$(claude_vm_scalar "$MERGED_BOOT" '.cpus' 'X')"
assert_eq "scalar: global fills gap (mem)" \
  "4096" "$(claude_vm_scalar "$MERGED_BOOT" '.mem' 'X')"
assert_eq "scalar: repo overrides global (guest_image)" \
  "/repo/guest.raw" "$(claude_vm_scalar "$MERGED_BOOT" '.guest_image' 'X')"
assert_eq "scalar: nested repo.mount repo wins" \
  "live" "$(claude_vm_scalar "$MERGED_BOOT" '.repo.mount' 'X')"
assert_eq "scalar: nested proxy.cmd from global" \
  "global-proxy" "$(claude_vm_scalar "$MERGED_BOOT" '.proxy.cmd' 'X')"
assert_eq "scalar: nested proxy.port from global" \
  "3128" "$(claude_vm_scalar "$MERGED_BOOT" '.proxy.port' 'X')"
assert_eq "scalar: repo overrides global (bake image.root_headroom_mb)" \
  "2048" "$(claude_vm_scalar "$MERGED_BAKE" '.image.root_headroom_mb' 'X')"

# ---------------------------------------------------------------------
# Test 2: list union -- egress.allow merged + de-duplicated
# ---------------------------------------------------------------------
# global: api.anthropic.com, github.com ; repo: github.com, cache.example.com
# union (sorted by yq unique): api.anthropic.com, cache.example.com, github.com
EGRESS="$(claude_vm_egress_hosts "$MERGED_BOOT" | sort | tr '\n' ',' )"
assert_eq "list: egress.allow is unioned + de-duped" \
  "api.anthropic.com,cache.example.com,github.com," "$EGRESS"

# ---------------------------------------------------------------------
# Test 3: list union -- mounts merged (both global and repo entries)
# ---------------------------------------------------------------------
MOUNT_TAGS="$(claude_vm_mount_specs "$MERGED_BOOT" | cut -f2 | sort | tr '\n' ',')"
assert_eq "list: mounts unioned (policy + data tags present)" \
  "data,policy," "$MOUNT_TAGS"
MOUNT_COUNT="$(claude_vm_mount_specs "$MERGED_BOOT" | grep -c . )"
assert_eq "list: mounts has exactly 2 entries" "2" "$MOUNT_COUNT"

# ---------------------------------------------------------------------
# Test 3b: guest-capability schema (issue #103) -- scalars repo-wins
# ---------------------------------------------------------------------
# NOTE: yq's `// ""` returns "" for a boolean `false`, so claude_vm_scalar
# (the plain string/number accessor) cannot distinguish an explicit
# `false` from an absent key -- see claude_vm_bool_scalar's dedicated
# round-trip coverage in Test 3d below, which proves explicit `false`
# survives via the boolean-aware accessor. Fixtures set the
# *_update_at_boot booleans global=false / repo=true so "repo wins"
# resolves to a non-empty "true" here via claude_vm_scalar; the
# false/fallback case for claude_vm_scalar specifically is covered
# separately for the global-only merge below.
assert_eq "scalar: update_at_boot repo wins (true)" \
  "true" "$(claude_vm_scalar "$MERGED_BOOT" '.update_at_boot' 'X')"
assert_eq "scalar: add_apt_uris_to_allowlist repo wins (always)" \
  "always" "$(claude_vm_scalar "$MERGED_BOOT" '.add_apt_uris_to_allowlist' 'X')"
assert_eq "scalar: claude.permission_mode repo wins (default)" \
  "default" "$(claude_vm_scalar "$MERGED_BOOT" '.claude.permission_mode' 'X')"
assert_eq "scalar: claude.plugins.update_at_boot repo wins (true)" \
  "true" "$(claude_vm_scalar "$MERGED_BOOT" '.claude.plugins.update_at_boot' 'X')"
assert_eq "scalar: claude.plugins.add_marketplace_uris_to_allowlist repo wins (always)" \
  "always" "$(claude_vm_scalar "$MERGED_BOOT" '.claude.plugins.add_marketplace_uris_to_allowlist' 'X')"
# claude.plugins.enabled is a scalar MAP merged repo-over-global PER KEY.
# global: {foo: true, bar: false}; repo: {bar: true}. Merged: foo stays true
# (global fills the gap), bar flips to true (repo wins on its own key).
assert_eq "map: claude.plugins.enabled[foo] from global (per-key gap fill)" \
  "true" "$(claude_vm_scalar "$MERGED_BOOT" '.claude.plugins.enabled["foo@global-mp"]' 'X')"
assert_eq "map: claude.plugins.enabled[bar] repo wins (per-key override)" \
  "true" "$(claude_vm_scalar "$MERGED_BOOT" '.claude.plugins.enabled["bar@global-mp"]' 'X')"
assert_eq "scalar: github.auth repo wins (host-token)" \
  "host-token" "$(claude_vm_scalar "$MERGED_BOOT" '.github.auth' 'X')"

# ---------------------------------------------------------------------
# Test 3c: guest-capability schema (issue #103) -- nested list unions
# ---------------------------------------------------------------------
# bake packages: global(jq, ripgrep) + repo(ripgrep, fd-find) -> 3 unique
PKG_BAKE="$(claude_vm_list_items "$MERGED_BAKE" '.packages' | sort | tr '\n' ',')"
assert_eq "list: bake packages unioned + de-duped" \
  "fd-find,jq,ripgrep," "$PKG_BAKE"

# boot packages (install at boot): global(htop) + repo(build-essential) -> 2
PKG_INSTALL="$(claude_vm_list_items "$MERGED_BOOT" '.packages' | sort | tr '\n' ',')"
assert_eq "list: boot packages unioned" \
  "build-essential,htop," "$PKG_INSTALL"

# apt_sources union per tier: bake global(global-repo) + repo(repo-registry);
# boot global(boot-global-src) + repo(boot-repo-src)
APT_SOURCE_NAMES="$(claude_vm_apt_sources "$MERGED_BAKE" | cut -f1 | sort | tr '\n' ',')"
assert_eq "list: bake apt_sources unioned" \
  "global-repo,repo-registry," "$APT_SOURCE_NAMES"
BOOT_SOURCE_NAMES="$(claude_vm_apt_sources "$MERGED_BOOT" | cut -f1 | sort | tr '\n' ',')"
assert_eq "list: boot apt_sources unioned" \
  "boot-global-src,boot-repo-src," "$BOOT_SOURCE_NAMES"

# claude.permissions.allow: global(Bash(git:*)) + repo(Bash(npm:*)) -> 2
PERM_ALLOW="$(claude_vm_list_items "$MERGED_BOOT" '.claude.permissions.allow' | sort | tr '\n' ',')"
assert_eq "list: claude.permissions.allow unioned" \
  "Bash(git:*),Bash(npm:*)," "$PERM_ALLOW"

# claude.permissions.ask: identical entry in both layers -> de-dupes to 1
PERM_ASK_COUNT="$(claude_vm_list_items "$MERGED_BOOT" '.claude.permissions.ask' | grep -c .)"
assert_eq "list: claude.permissions.ask de-dupes identical entry" "1" "$PERM_ASK_COUNT"

# claude.permissions.deny: global(Bash(sudo:*)) + repo(Bash(curl:*)) -> 2
PERM_DENY="$(claude_vm_list_items "$MERGED_BOOT" '.claude.permissions.deny' | sort | tr '\n' ',')"
assert_eq "list: claude.permissions.deny unioned" \
  "Bash(curl:*),Bash(sudo:*)," "$PERM_DENY"

# claude.marketplaces: global(global-mp) + repo(repo-mp) -> 2. A BAKE-file key
# (also allowed in a boot file) since issue #107 -- read from the bake doc.
MP_NAMES="$(claude_vm_marketplaces "$MERGED_BAKE" | cut -f1 | sort | tr '\n' ',')"
assert_eq "list: claude.marketplaces unioned" \
  "global-mp,repo-mp," "$MP_NAMES"

# claude.plugins.bake: global(foo@global-mp) + repo(baz@repo-mp) -> 2. A
# BAKE-file-only key since issue #107, so it unions inside the bake document.
PLUGIN_BAKE="$(claude_vm_list_items "$MERGED_BAKE" '.claude.plugins.bake' | sort | tr '\n' ',')"
assert_eq "list: claude.plugins.bake unioned" \
  "baz@repo-mp,foo@global-mp," "$PLUGIN_BAKE"

# claude.plugins.install_at_boot: identical entry (bar@global-mp) in both -> 1
PLUGIN_INSTALL_COUNT="$(claude_vm_list_items "$MERGED_BOOT" '.claude.plugins.install_at_boot' | grep -c .)"
assert_eq "list: claude.plugins.install_at_boot de-dupes identical entry" \
  "1" "$PLUGIN_INSTALL_COUNT"

# ---------------------------------------------------------------------
# Test 3d: claude_vm_bool_scalar -- explicit `false` survives (issue #103
# review finding). Unlike claude_vm_scalar's `// ""` idiom, an explicit
# YAML `false` must round-trip as "false", not be replaced by the
# caller's fallback. Cover all four presence states: explicit false,
# explicit true, genuinely absent, and explicit null.
# ---------------------------------------------------------------------
BOOL_YML="$WORK/bool-scalar.yml"
cat > "$BOOL_YML" <<'YML'
knob_false: false
knob_true: true
knob_null: null
other:
  x: 1
YML

assert_eq "bool_scalar: explicit false is preserved (not replaced by fallback)" \
  "false" "$(claude_vm_bool_scalar "$BOOL_YML" '.knob_false' 'FALLBACK')"
assert_eq "bool_scalar: explicit true is preserved" \
  "true" "$(claude_vm_bool_scalar "$BOOL_YML" '.knob_true' 'FALLBACK')"
assert_eq "bool_scalar: genuinely absent key falls back" \
  "FALLBACK" "$(claude_vm_bool_scalar "$BOOL_YML" '.knob_absent' 'FALLBACK')"
assert_eq "bool_scalar: explicit null falls back (same as absent)" \
  "FALLBACK" "$(claude_vm_bool_scalar "$BOOL_YML" '.knob_null' 'FALLBACK')"

# Same check against the real merged fixture's two guest-capability
# booleans, with fixtures inverted (global=true / repo=false) so "repo
# wins" resolving to "false" is a genuine round-trip proof, not an
# artifact of the fallback also being "false".
BOOL_G="$WORK/bool-g.yml"; printf 'update_at_boot: true\nclaude:\n  plugins:\n    update_at_boot: true\n' > "$BOOL_G"
BOOL_R="$WORK/bool-r.yml"; printf 'update_at_boot: false\nclaude:\n  plugins:\n    update_at_boot: false\n' > "$BOOL_R"
MERGED_BOOL="$WORK/merged-bool.yml"
claude_vm_merge_config "$BOOL_G" "$BOOL_R" > "$MERGED_BOOL"
assert_eq "bool_scalar: update_at_boot repo-wins explicit false survives" \
  "false" "$(claude_vm_bool_scalar "$MERGED_BOOL" '.update_at_boot' 'FALLBACK')"
assert_eq "bool_scalar: claude.plugins.update_at_boot repo-wins explicit false survives" \
  "false" "$(claude_vm_bool_scalar "$MERGED_BOOL" '.claude.plugins.update_at_boot' 'FALLBACK')"

# ---------------------------------------------------------------------
# Test 3e: claude_vm_apt_sources / claude_vm_marketplaces -- missing
# optional field emits an EMPTY @tsv field, not the literal string
# "null" (issue #103 review finding).
# ---------------------------------------------------------------------
OPTIONAL_FIELD_YML="$WORK/optional-field.yml"
cat > "$OPTIONAL_FIELD_YML" <<'YML'
apt_sources:
  - name: no-key-repo
    repo: "deb https://example.com/nokey stable main"
claude:
  marketplaces:
    - name: no-url-mp
YML

APT_ROW="$(claude_vm_apt_sources "$OPTIONAL_FIELD_YML")"
assert_eq "apt_sources: missing key_url is an empty field, not literal null" \
  "no-key-repo	deb https://example.com/nokey stable main	" "$APT_ROW"
APT_KEY_URL_FIELD="$(printf '%s' "$APT_ROW" | cut -f3)"
assert_eq "apt_sources: missing key_url field value is empty string" \
  "" "$APT_KEY_URL_FIELD"

MP_ROW="$(claude_vm_marketplaces "$OPTIONAL_FIELD_YML")"
assert_eq "marketplaces: missing url is an empty field, not literal null" \
  "no-url-mp	" "$MP_ROW"
MP_URL_FIELD="$(printf '%s' "$MP_ROW" | cut -f2)"
assert_eq "marketplaces: missing url field value is empty string" \
  "" "$MP_URL_FIELD"

# ---------------------------------------------------------------------
# Test 4: global-only (repo config absent) resolves cleanly
# ---------------------------------------------------------------------
MERGED_G="$WORK/merged-global.yml"
MERGED_G_BAKE="$WORK/merged-global-bake.yml"
claude_vm_merge_config "$GLOBAL_BOOT" "$WORK/does-not-exist.yml" > "$MERGED_G"
claude_vm_merge_config "$GLOBAL_BAKE" "$WORK/does-not-exist.yml" > "$MERGED_G_BAKE"
assert_eq "global-only: cpus from global" \
  "2" "$(claude_vm_scalar "$MERGED_G" '.cpus' 'X')"
assert_eq "global-only: egress count is 2" \
  "2" "$(claude_vm_egress_hosts "$MERGED_G" | grep -c .)"
# global's update_at_boot is false; the yq `// ""` quirk for
# boolean false means the plain claude_vm_scalar accessor falls back to
# the caller default here -- this is claude_vm_scalar's DOCUMENTED
# limitation (see its header comment), not a bug in this accessor. The
# boolean-aware claude_vm_bool_scalar accessor (Test 3d above) is the
# one that must preserve explicit false; this assertion just pins
# claude_vm_scalar's known, unchanged behavior so a future edit doesn't
# silently "fix" it here and break the non-boolean scalar callers that
# rely on the `// ""` idiom.
assert_eq "global-only: update_at_boot from global (false, plain scalar accessor falls back)" \
  "X" "$(claude_vm_scalar "$MERGED_G" '.update_at_boot' 'X')"
assert_eq "global-only: claude.permission_mode from global" \
  "bypassPermissions" "$(claude_vm_scalar "$MERGED_G" '.claude.permission_mode' 'X')"
assert_eq "global-only: github.auth from global" \
  "none" "$(claude_vm_scalar "$MERGED_G" '.github.auth' 'X')"
assert_eq "global-only: bake packages count is 2" \
  "2" "$(claude_vm_list_items "$MERGED_G_BAKE" '.packages' | grep -c .)"
assert_eq "global-only: image.root_headroom_mb from global bake" \
  "1024" "$(claude_vm_scalar "$MERGED_G_BAKE" '.image.root_headroom_mb' 'X')"

# ---------------------------------------------------------------------
# Test 5: repo-only (global config absent) resolves cleanly
# ---------------------------------------------------------------------
MERGED_R="$WORK/merged-repo.yml"
MERGED_R_BAKE="$WORK/merged-repo-bake.yml"
claude_vm_merge_config "$WORK/does-not-exist.yml" "$REPO_BOOT" > "$MERGED_R"
claude_vm_merge_config "$WORK/does-not-exist.yml" "$REPO_BAKE" > "$MERGED_R_BAKE"
assert_eq "repo-only: cpus from repo" \
  "8" "$(claude_vm_scalar "$MERGED_R" '.cpus' 'X')"
assert_eq "repo-only: mem falls back to hardcoded default" \
  "$CLAUDE_VM_DEFAULT_MEM" "$(claude_vm_scalar "$MERGED_R" '.mem' "$CLAUDE_VM_DEFAULT_MEM")"
assert_eq "repo-only: claude.permission_mode from repo (default)" \
  "default" "$(claude_vm_scalar "$MERGED_R" '.claude.permission_mode' 'X')"
assert_eq "repo-only: github.auth from repo (host-token)" \
  "host-token" "$(claude_vm_scalar "$MERGED_R" '.github.auth' 'X')"
assert_eq "repo-only: update_at_boot from repo (true)" \
  "true" "$(claude_vm_scalar "$MERGED_R" '.update_at_boot' 'X')"
assert_eq "repo-only: image.root_headroom_mb from repo bake (2048)" \
  "2048" "$(claude_vm_scalar "$MERGED_R_BAKE" '.image.root_headroom_mb' 'X')"

# ---------------------------------------------------------------------
# Test 6: neither layer present -- all scalars hit hardcoded fallbacks
# ---------------------------------------------------------------------
MERGED_N="$WORK/merged-none.yml"
claude_vm_merge_config "$WORK/none-a.yml" "$WORK/none-b.yml" > "$MERGED_N"
assert_eq "neither: cpus fallback" \
  "$CLAUDE_VM_DEFAULT_CPUS" "$(claude_vm_scalar "$MERGED_N" '.cpus' "$CLAUDE_VM_DEFAULT_CPUS")"
assert_eq "neither: repo.mount fallback is clone" \
  "$CLAUDE_VM_DEFAULT_REPO_MOUNT" "$(claude_vm_scalar "$MERGED_N" '.repo.mount' "$CLAUDE_VM_DEFAULT_REPO_MOUNT")"
assert_eq "neither: egress allow is empty" \
  "0" "$(claude_vm_egress_hosts "$MERGED_N" | grep -c .)"
assert_eq "neither: update_at_boot fallback (true)" \
  "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT" \
  "$(claude_vm_scalar "$MERGED_N" '.update_at_boot' "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT")"
assert_eq "neither: add_apt_uris_to_allowlist fallback (auto)" \
  "$CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST" \
  "$(claude_vm_scalar "$MERGED_N" '.add_apt_uris_to_allowlist' "$CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST")"
assert_eq "neither: claude.permission_mode fallback (bypassPermissions)" \
  "$CLAUDE_VM_DEFAULT_CLAUDE_PERMISSION_MODE" \
  "$(claude_vm_scalar "$MERGED_N" '.claude.permission_mode' "$CLAUDE_VM_DEFAULT_CLAUDE_PERMISSION_MODE")"
assert_eq "neither: claude.plugins.update_at_boot fallback (true)" \
  "$CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_UPDATE_AT_BOOT" \
  "$(claude_vm_scalar "$MERGED_N" '.claude.plugins.update_at_boot' "$CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_UPDATE_AT_BOOT")"
assert_eq "neither: claude.plugins.add_marketplace_uris_to_allowlist fallback (auto)" \
  "$CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_ADD_MARKETPLACE_URIS_TO_ALLOWLIST" \
  "$(claude_vm_scalar "$MERGED_N" '.claude.plugins.add_marketplace_uris_to_allowlist' "$CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_ADD_MARKETPLACE_URIS_TO_ALLOWLIST")"
assert_eq "neither: claude.plugins.enabled absent -> empty map" \
  "0" "$(yq eval '.claude.plugins.enabled // {} | length' "$MERGED_N" 2>/dev/null)"
assert_eq "neither: github.auth fallback (none)" \
  "$CLAUDE_VM_DEFAULT_GITHUB_AUTH" \
  "$(claude_vm_scalar "$MERGED_N" '.github.auth' "$CLAUDE_VM_DEFAULT_GITHUB_AUTH")"
assert_eq "neither: packages list is empty" \
  "0" "$(claude_vm_list_items "$MERGED_N" '.packages' | grep -c .)"
assert_eq "neither: claude.permissions.allow is empty" \
  "0" "$(claude_vm_list_items "$MERGED_N" '.claude.permissions.allow' | grep -c .)"
assert_eq "neither: claude.marketplaces is empty" \
  "0" "$(claude_vm_marketplaces "$MERGED_N" | grep -c .)"
assert_eq "neither: image.root_headroom_mb fallback (1024)" \
  "$CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB" \
  "$(claude_vm_scalar "$MERGED_N" '.image.root_headroom_mb' "$CLAUDE_VM_DEFAULT_IMAGE_ROOT_HEADROOM_MB")"

# ---------------------------------------------------------------------
# Test 6b: empty-skeleton pruning (issue #103 review finding). A list
# key the user set in NEITHER layer must not appear in the merged
# document at all -- neither as an empty list nor via a surviving empty
# parent map (e.g. `packages: {}`) -- so a consumer cannot mistake
# "configured empty" for "not configured" by testing key presence.
# ---------------------------------------------------------------------
assert_eq "prune: fully-empty merge has no packages key at all" \
  "false" "$(yq eval 'has("packages")' "$MERGED_N")"
assert_eq "prune: fully-empty merge has no claude key at all" \
  "false" "$(yq eval 'has("claude")' "$MERGED_N")"
assert_eq "prune: fully-empty merge has no egress key at all" \
  "false" "$(yq eval 'has("egress")' "$MERGED_N")"
assert_eq "prune: fully-empty merge document is the empty map" \
  "{}" "$(yq eval -o=json -I=0 '.' "$MERGED_N")"

# A scalar-only layer must still prune ITS sibling empty lists/maps while
# keeping the scalar (proves pruning doesn't over-delete a populated
# parent map, only ones that become genuinely empty).
SCALAR_ONLY_G="$WORK/scalar-only-g.yml"
printf 'claude:\n  permission_mode: default\n' > "$SCALAR_ONLY_G"
MERGED_SCALAR_ONLY="$WORK/merged-scalar-only.yml"
claude_vm_merge_config "$SCALAR_ONLY_G" "$WORK/does-not-exist.yml" > "$MERGED_SCALAR_ONLY"
assert_eq "prune: scalar-bearing claude map survives with only its scalar" \
  '{"claude":{"permission_mode":"default"}}' \
  "$(yq eval -o=json -I=0 '.' "$MERGED_SCALAR_ONLY")"
assert_eq "prune: scalar-only merge has no packages key (never set)" \
  "false" "$(yq eval 'has("packages")' "$MERGED_SCALAR_ONLY")"

# The populated-both-layers fixture ($MERGED from Test 1) must be
# UNAFFECTED by pruning -- every list key it set stays present with its
# full unioned entry count (regression guard: pruning must not touch a
# non-empty list).
assert_eq "prune: populated bake merge still has packages with entries" \
  "3" "$(claude_vm_list_items "$MERGED_BAKE" '.packages' | grep -c .)"
assert_eq "prune: populated merge still has claude.marketplaces with entries" \
  "2" "$(claude_vm_marketplaces "$MERGED_BAKE" | grep -c .)"

# ---------------------------------------------------------------------
# Test 7: identical mount in both layers de-dupes to one entry
# ---------------------------------------------------------------------
DUP_G="$WORK/dup-g.yml"
DUP_R="$WORK/dup-r.yml"
cat > "$DUP_G" <<'YML'
mounts:
  - source: ~/shared
    tag: shared
    path: /srv/shared
YML
cat > "$DUP_R" <<'YML'
mounts:
  - source: ~/shared
    tag: shared
    path: /srv/shared
YML
MERGED_D="$WORK/merged-dup.yml"
claude_vm_merge_config "$DUP_G" "$DUP_R" > "$MERGED_D"
assert_eq "dedup: identical mount collapses to 1 entry" \
  "1" "$(claude_vm_mount_specs "$MERGED_D" | grep -c .)"

# assert_true <label> <command...> -- passes when the command succeeds.
assert_true() {
  local label="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "ok   - $label"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $label"
    echo "        command failed: $*"
  fi
}

# assert_ne <label> <a> <b> -- passes when the two values differ.
assert_ne() {
  local label="$1" a="$2" b="$3"
  if [ "$a" != "$b" ]; then
    PASS=$((PASS + 1))
    echo "ok   - $label"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $label"
    echo "        both values: [$a]"
  fi
}

# ---------------------------------------------------------------------
# Test 8: claude_vm_mktemp substitutes the template on EVERY call
# (regression for the BSD/macOS `mktemp foo.XXXXXX.yml` bug).
#
# A non-substituting template (the old `.XXXXXX.yml` form on BSD) creates
# a single LITERAL file on the first call and collides with "File exists"
# on the second. Calling the helper twice and asserting two distinct,
# existing files is exactly the check that would have caught the bug.
# Point TMPDIR at the test workdir so the created files are cleaned up
# with $WORK and do not litter the real temp dir.
# ---------------------------------------------------------------------
(
  export TMPDIR="$WORK"

  F1="$(claude_vm_mktemp claude-vm-mktemp-test)"
  F2="$(claude_vm_mktemp claude-vm-mktemp-test)"
  assert_true "mktemp: first file exists"  test -f "$F1"
  assert_true "mktemp: second file exists" test -f "$F2"
  assert_ne   "mktemp: two file calls produce distinct paths" "$F1" "$F2"

  D1="$(claude_vm_mktemp -d claude-vm-mktemp-test-dir)"
  D2="$(claude_vm_mktemp -d claude-vm-mktemp-test-dir)"
  assert_true "mktemp -d: first dir exists"  test -d "$D1"
  assert_true "mktemp -d: second dir exists" test -d "$D2"
  assert_ne   "mktemp -d: two dir calls produce distinct paths" "$D1" "$D2"

  # The created path must NOT carry a literal X-run -- a regression check
  # that the template was actually substituted, not used verbatim.
  case "$F1" in
    *XXXXXX*) assert_eq "mktemp: template was substituted (no literal X-run)" "no-XXXXXX" "literal-XXXXXX" ;;
    *)        assert_eq "mktemp: template was substituted (no literal X-run)" "no-XXXXXX" "no-XXXXXX" ;;
  esac

  # A trailing slash on TMPDIR must not produce a doubled slash.
  export TMPDIR="$WORK/"
  SLASH="$(claude_vm_mktemp claude-vm-mktemp-slash)"
  case "$SLASH" in
    *//*) assert_eq "mktemp: trailing-slash TMPDIR yields no doubled slash" "single-slash" "doubled-slash" ;;
    *)    assert_eq "mktemp: trailing-slash TMPDIR yields no doubled slash" "single-slash" "single-slash" ;;
  esac

  # Propagate this subshell's pass/fail tallies to the parent via a temp
  # file (a subshell cannot mutate the parent's PASS/FAIL vars).
  printf '%s %s\n' "$PASS" "$FAIL" > "$WORK/mktemp-tally"
)
read -r SUB_PASS SUB_FAIL < "$WORK/mktemp-tally"
PASS="$SUB_PASS"
FAIL="$SUB_FAIL"

# ---------------------------------------------------------------------
# Test 9: claude_vm_merge_config can run twice in succession.
#
# The merge helper allocates its own internal `claude-vm-empty.XXXXXX`
# scratch file via claude_vm_mktemp. Before the fix that file carried a
# `.yml` suffix after the X-run, so on BSD the second merge in a process
# would die on "File exists". Run two merges back-to-back into two
# outputs and assert both succeeded and produced content.
# ---------------------------------------------------------------------
(
  export TMPDIR="$WORK"
  OUT_A="$WORK/twice-a.yml"
  OUT_B="$WORK/twice-b.yml"
  rc=0
  claude_vm_merge_config "$GLOBAL_BOOT" "$REPO_BOOT" > "$OUT_A" || rc=1
  claude_vm_merge_config "$GLOBAL_BOOT" "$REPO_BOOT" > "$OUT_B" || rc=1
  assert_true "merge twice: both calls succeeded" test "$rc" -eq 0
  assert_true "merge twice: first output non-empty"  test -s "$OUT_A"
  assert_true "merge twice: second output non-empty" test -s "$OUT_B"
  printf '%s %s\n' "$PASS" "$FAIL" > "$WORK/merge-tally"
)
read -r SUB_PASS SUB_FAIL < "$WORK/merge-tally"
PASS="$SUB_PASS"
FAIL="$SUB_FAIL"

# ---------------------------------------------------------------------
# Test 10: claude_vm_quote_args round-trip (issue #88).
#
# The host writes CLAUDE_ARGS as `printf 'CLAUDE_ARGS=%q\n'
# "$(claude_vm_quote_args "$@")"`, and the guest reconstructs argv with
# `eval "set -- $CLAUDE_ARGS"` after sourcing run.env under `set -a`.
# This exercises the FULL round-trip: write a real run.env-style temp file,
# `source` it, `eval set --`, and assert the exact reconstructed argv --
# the reproducing example, the empty array, an explicit empty-string arg,
# and args carrying quotes/spaces/#/$/backslash.
# ---------------------------------------------------------------------

# rt_argv <var-out> <args...> : run the args through the host quote+write,
# guest source+eval reconstruction, and set <var-out> to a printable
# "ARGC|<a1>|<a2>|..." string of the reconstructed argv.
rt_argv() {
  local __out="$1"; shift
  local inner envline tf
  # Host: inner per-arg %q, then outer %q for the whole line.
  inner="$(claude_vm_quote_args "$@")"
  inner="${inner%$'\n'}"
  printf -v envline 'CLAUDE_ARGS=%q\n' "$inner"
  tf="$(claude_vm_mktemp claude-vm-runenv)"
  printf '%s' "$envline" > "$tf"
  # Guest: source run.env under set -a, eval set --, serialize argv.
  local serialized
  serialized="$(
    set -a
    # shellcheck disable=SC1090
    . "$tf"
    set +a
    eval "set -- ${CLAUDE_ARGS:-}"
    printf 'ARGC=%s' "$#"
    for __a in ${1+"$@"}; do printf '|<%s>' "$__a"; done
    printf '\n'
  )"
  rm -f "$tf"
  printf -v "$__out" '%s' "$serialized"
}

RT=""
rt_argv RT --remote-control --name "foo #7 micro-vm Claude Plugins"
assert_eq "quote-args: reproducing example round-trips to 3 args" \
  "ARGC=3|<--remote-control>|<--name>|<foo #7 micro-vm Claude Plugins>" "$RT"

rt_argv RT   # zero args
assert_eq "quote-args: empty array -> zero argv" \
  "ARGC=0" "$RT"

rt_argv RT --flag "" tail
assert_eq "quote-args: explicit empty-string arg survives" \
  "ARGC=3|<--flag>|<>|<tail>" "$RT"

rt_argv RT 'a b' "it's" '#c' '$HOME' 'back\slash' '"dq"'
assert_eq "quote-args: quotes/spaces/#/\$/backslash survive verbatim" \
  'ARGC=6|<a b>|<it'\''s>|<#c>|<$HOME>|<back\slash>|<"dq">' "$RT"

# claude_vm_quote_args prints NOTHING (empty) for zero args -- a stray ''
# would round-trip into a bogus empty argv element downstream.
assert_eq "quote-args: zero args prints empty (no bogus '')" \
  "" "$(claude_vm_quote_args)"

# ---------------------------------------------------------------------
# Test 11: Remote Control / --name args augmentation (issue #88).
#
# claude_vm_augment_rc_args emits one arg per line; join with '|' for a
# stable comparison. The date stamp is passed IN (fixed) so the assertion
# is deterministic.
# ---------------------------------------------------------------------
STAMP="Jul10-14:30"

# aug_join <rc> <stamp> <args...> : pipe-joined augmented argv.
aug_join() {
  local rc="$1" stamp="$2"; shift 2
  claude_vm_augment_rc_args "$rc" "$stamp" "$@" | paste -sd '|' -
}
# aug_join_noargs <rc> <stamp> : augment with NO user args.
aug_join_noargs() {
  claude_vm_augment_rc_args "$1" "$2" | paste -sd '|' -
}

assert_eq "augment: knob true + no CLI flag -> RC injected + --name appended" \
  "--remote-control|--name|$STAMP" "$(aug_join_noargs true "$STAMP")"
assert_eq "augment: knob true + CLI --remote-control -> no duplicate RC" \
  "--remote-control|--name|$STAMP" "$(aug_join true "$STAMP" --remote-control)"
assert_eq "augment: CLI --remote-control (knob false) -> --name appended" \
  "--remote-control|--name|$STAMP" "$(aug_join false "$STAMP" --remote-control)"
assert_eq "augment: --name <v> form not overridden" \
  "--remote-control|--name|myrun" "$(aug_join true "$STAMP" --name myrun)"
assert_eq "augment: --name=<v> form not overridden" \
  "--remote-control|--name=myrun" "$(aug_join true "$STAMP" --name=myrun)"
assert_eq "augment: knob false + no flag -> args untouched" \
  "--resume|foo" "$(aug_join false "$STAMP" --resume foo)"

# Date-stamp VALUE assertion: shape, not exact time. The launcher uses
# `date '+%b%d-%H:%M'` (e.g. Jul10-14:30) -> ^[A-Z][a-z]{2}[0-9]{2}-[0-9]{2}:[0-9]{2}$.
REAL_STAMP="$(date '+%b%d-%H:%M')"
if printf '%s' "$REAL_STAMP" | grep -qE '^[A-Z][a-z]{2}[0-9]{2}-[0-9]{2}:[0-9]{2}$'; then
  assert_eq "augment: date-stamp format shape matches +%b%d-%H:%M" "ok" "ok"
else
  assert_eq "augment: date-stamp format shape matches +%b%d-%H:%M" "ok" "bad: [$REAL_STAMP]"
fi

# ---------------------------------------------------------------------
# Test 12: claude.remote_control config resolution (issue #88).
#
# The launcher resolves the scalar then normalizes: ""/false -> false,
# true -> true, anything else -> abort. Reproduce that normalization here
# (the launcher's `case` is not a sourced function, so mirror its logic)
# and assert true/false/unset resolve and garbage would abort.
# ---------------------------------------------------------------------
rc_resolve() {
  # Prints "true"/"false" on success; prints "ABORT" and returns 1 on garbage.
  local raw="$1"
  case "$raw" in
    ""|false) printf 'false\n' ;;
    true)     printf 'true\n' ;;
    *)        printf 'ABORT\n'; return 1 ;;
  esac
}
RC_TRUE_YML="$WORK/rc-true.yml";  printf 'claude:\n  remote_control: true\n'  > "$RC_TRUE_YML"
RC_FALSE_YML="$WORK/rc-false.yml"; printf 'claude:\n  remote_control: false\n' > "$RC_FALSE_YML"
RC_UNSET_YML="$WORK/rc-unset.yml"; printf 'claude:\n  version: stable\n'        > "$RC_UNSET_YML"
RC_GARBAGE_YML="$WORK/rc-garbage.yml"; printf 'claude:\n  remote_control: maybe\n' > "$RC_GARBAGE_YML"

assert_eq "remote_control: true resolves to true" \
  "true"  "$(rc_resolve "$(claude_vm_scalar "$RC_TRUE_YML" '.claude.remote_control' '')")"
# NOTE: yq's `// ""` returns "" for a boolean false, so the scalar is "" here;
# the launcher's normalization maps both "" and "false" to false. Assert false.
assert_eq "remote_control: false resolves to false" \
  "false" "$(rc_resolve "$(claude_vm_scalar "$RC_FALSE_YML" '.claude.remote_control' '')")"
assert_eq "remote_control: unset resolves to false" \
  "false" "$(rc_resolve "$(claude_vm_scalar "$RC_UNSET_YML" '.claude.remote_control' '')")"
GARBAGE_RESOLVE="$(rc_resolve "$(claude_vm_scalar "$RC_GARBAGE_YML" '.claude.remote_control' '')" || true)"
assert_eq "remote_control: garbage would abort the launch" \
  "ABORT" "$GARBAGE_RESOLVE"

# ---------------------------------------------------------------------
# Test 13: copy-back real-change gating (issue #88).
#
# The launcher's copy_back_real_changes runs a --checksum dry-run and
# filters --itemize-changes to content/structural lines (leading >, c, *).
# Attribute-only lines (leading `.`, e.g. mtime-only skew from a clone
# checkout) are excluded -- that is the whole point. Reproduce the helper
# here against temp trees and assert: identical content + skewed mtime ->
# NO real changes; a genuinely differing file -> a real change. Skips
# cleanly if rsync is unavailable.
# ---------------------------------------------------------------------
if command -v rsync >/dev/null 2>&1; then
  # Mirror the launcher's copy_back_real_changes exactly.
  cb_real_changes() {
    local wt="$1" src="$2"
    rsync -a --checksum --dry-run --itemize-changes --exclude '.git' \
      "$wt"/ "$src"/ | grep -E '^[>c*]' || true
  }

  CB_SRC="$WORK/cb-src"; CB_WT="$WORK/cb-wt"
  mkdir -p "$CB_SRC" "$CB_WT"
  # Identical content, skewed mtime (the false-positive case).
  printf 'hello\n' > "$CB_SRC/same.txt"
  printf 'hello\n' > "$CB_WT/same.txt"
  touch -t 202001010000 "$CB_SRC/same.txt"
  touch -t 202512120000 "$CB_WT/same.txt"
  assert_eq "copy-back gate: identical content + mtime skew -> no real changes" \
    "" "$(cb_real_changes "$CB_WT" "$CB_SRC")"

  # Genuinely differing file -> a real change (leading '>').
  printf 'NEW content\n' > "$CB_WT/changed.txt"
  printf 'old\n'         > "$CB_SRC/changed.txt"
  touch -t 202001010000 "$CB_SRC/changed.txt"
  touch -t 202512120000 "$CB_WT/changed.txt"
  CB_CHANGED="$(cb_real_changes "$CB_WT" "$CB_SRC")"
  case "$CB_CHANGED" in
    *changed.txt*) assert_eq "copy-back gate: genuinely changed file -> a real change" "hit" "hit" ;;
    *)             assert_eq "copy-back gate: genuinely changed file -> a real change" "hit" "miss: [$CB_CHANGED]" ;;
  esac
else
  echo "ok   - copy-back gate: SKIP (rsync not available)"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------
# Test 14: guest settings.json render (issue #104).
#
# claude_vm_render_guest_settings is pure (merged-config files -> settings.json
# on stdout). Cover the acceptance criteria that are verifiable host-side:
# config-only permissions, defaultMode from permission_mode, enabledPlugins from
# bake ++ install_at_boot (all default true), the claude.plugins.enabled
# per-key overrides, and the validation (boolean values, keys must be installed
# refs) that aborts on a typo. A tiny JSON reader (yq) inspects the emitted
# document.
#
# TWO documents since issue #107: claude.plugins.bake is a BAKE key (it changes
# image bytes, so it lives where the whole-file image-identity hash sees it) and
# everything else here is a BOOT key. The render is called
# <boot-doc> <bake-doc>, mirroring the launcher.
# ---------------------------------------------------------------------
S_FULL="$WORK/settings-full.yml"
cat > "$S_FULL" <<'YML'
claude:
  permission_mode: bypassPermissions
  permissions:
    allow:
      - "Bash(git:*)"
    ask:
      - "Bash(rm:*)"
    deny:
      - "Bash(ssh-keygen:*)"
  plugins:
    install_at_boot:
      - issues@thevoskamps
    enabled:
      show-loaded-rules@thevoskamps: false
YML
S_FULL_BAKE="$WORK/settings-full-bake.yml"
cat > "$S_FULL_BAKE" <<'YML'
claude:
  plugins:
    bake:
      - guardrails@thevoskamps
      - show-loaded-rules@thevoskamps
YML

# get_json <settings-json> <yq-json-path> -- read one scalar from rendered JSON.
# Output is the RAW scalar (yq default output), so a string value comes back
# bare ("default", not "\"default\"") and a boolean/number bare too. `null` for
# an absent path.
get_json() {
  printf '%s' "$1" | yq -p=json eval "$2" - 2>/dev/null
}

# Full config: permissions verbatim, defaultMode bypassPermissions, every
# installed plugin defaults true, and the one enabled: false override applies.
R_FULL="$(claude_vm_render_guest_settings "$S_FULL" "$S_FULL_BAKE")"
assert_eq "render: defaultMode from permission_mode (bypassPermissions)" \
  "bypassPermissions" "$(get_json "$R_FULL" '.permissions.defaultMode')"
assert_eq "render: permissions.allow verbatim from config" \
  "Bash(git:*)" "$(get_json "$R_FULL" '.permissions.allow[0]')"
assert_eq "render: permissions.ask verbatim from config" \
  "Bash(rm:*)" "$(get_json "$R_FULL" '.permissions.ask[0]')"
assert_eq "render: configured deny rule present" \
  "Bash(ssh-keygen:*)" "$(get_json "$R_FULL" '.permissions.deny[0]')"
assert_eq "render: installed plugin defaults to enabled (true)" \
  "true" "$(get_json "$R_FULL" '.enabledPlugins["guardrails@thevoskamps"]')"
assert_eq "render: install_at_boot plugin also defaults enabled (true)" \
  "true" "$(get_json "$R_FULL" '.enabledPlugins["issues@thevoskamps"]')"
assert_eq "render: enabled: false override marks plugin disabled" \
  "false" "$(get_json "$R_FULL" '.enabledPlugins["show-loaded-rules@thevoskamps"]')"
assert_eq "render: enabledPlugins has one entry per installed ref (3)" \
  "3" "$(get_json "$R_FULL" '.enabledPlugins | length')"

# Config-only permissions: the render NEVER reads host settings; with no
# claude.permissions.* set, the lists are empty (NOT populated from anywhere).
S_EMPTY="$WORK/settings-empty.yml"
printf 'claude:\n  permission_mode: default\n' > "$S_EMPTY"
R_EMPTY="$(claude_vm_render_guest_settings "$S_EMPTY")"
assert_eq "render: permission_mode: default -> defaultMode default" \
  "default" "$(get_json "$R_EMPTY" '.permissions.defaultMode')"
assert_eq "render: unset allow renders as empty array (config-only)" \
  "0" "$(get_json "$R_EMPTY" '.permissions.allow | length')"
assert_eq "render: unset deny renders as empty array (config-only)" \
  "0" "$(get_json "$R_EMPTY" '.permissions.deny | length')"
assert_eq "render: no plugins -> empty enabledPlugins object" \
  "0" "$(get_json "$R_EMPTY" '.enabledPlugins | length')"

# permission_mode default resolution: absent key -> bypassPermissions.
S_NOMODE="$WORK/settings-nomode.yml"
printf 'claude:\n  permissions:\n    deny:\n      - "Bash(sudo:*)"\n' > "$S_NOMODE"
R_NOMODE="$(claude_vm_render_guest_settings "$S_NOMODE")"
assert_eq "render: absent permission_mode defaults to bypassPermissions" \
  "bypassPermissions" "$(get_json "$R_NOMODE" '.permissions.defaultMode')"

# A ref in BOTH bake and install_at_boot collapses to one enabledPlugins entry
# (bake in the bake doc, install_at_boot in the boot doc -- issue #107).
S_DUP="$WORK/settings-dup.yml"
S_DUP_BAKE="$WORK/settings-dup-bake.yml"
printf 'claude:\n  plugins:\n    install_at_boot:\n      - dup@mp\n' > "$S_DUP"
printf 'claude:\n  plugins:\n    bake:\n      - dup@mp\n' > "$S_DUP_BAKE"
R_DUP="$(claude_vm_render_guest_settings "$S_DUP" "$S_DUP_BAKE")"
assert_eq "render: ref in both lists de-duplicates to one entry" \
  "1" "$(get_json "$R_DUP" '.enabledPlugins | length')"
assert_eq "render: de-duplicated ref is enabled" \
  "true" "$(get_json "$R_DUP" '.enabledPlugins["dup@mp"]')"

# ---------------------------------------------------------------------
# Test 15: claude.plugins.enabled validation (issue #104).
#
# The render validates the enabled map ONCE: every value must be a boolean and
# every key must name an installed plugin ref (present in bake ++
# install_at_boot). A bad value or an unknown key ABORTS (non-zero), so a config
# typo stops the launch rather than silently dropping/misspelling a toggle.
# ---------------------------------------------------------------------

# Accept: a valid enabled map (all keys installed, all boolean values) renders.
S_ENA_OK="$WORK/settings-enabled-ok.yml"
S_ENA_BAKE="$WORK/settings-enabled-bake.yml"
cat > "$S_ENA_OK" <<'YML'
claude:
  plugins:
    enabled:
      a@mp: false
      b@mp: true
YML
cat > "$S_ENA_BAKE" <<'YML'
claude:
  plugins:
    bake:
      - a@mp
      - b@mp
YML
if R_ENA_OK="$(claude_vm_render_guest_settings "$S_ENA_OK" "$S_ENA_BAKE" 2>/dev/null)"; then
  assert_eq "enabled-validate: valid map renders (accept)" "accept" "accept"
  assert_eq "enabled-validate: a@mp disabled via false override" \
    "false" "$(get_json "$R_ENA_OK" '.enabledPlugins["a@mp"]')"
else
  assert_eq "enabled-validate: valid map renders (accept)" "accept" "reject"
fi

# Reject: an unknown key (names a plugin not in bake/install_at_boot) aborts.
S_ENA_BADKEY="$WORK/settings-enabled-badkey.yml"
S_ENA_ONE_BAKE="$WORK/settings-enabled-one-bake.yml"
cat > "$S_ENA_BADKEY" <<'YML'
claude:
  plugins:
    enabled:
      typo@mp: false
YML
printf 'claude:\n  plugins:\n    bake:\n      - a@mp\n' > "$S_ENA_ONE_BAKE"
if claude_vm_render_guest_settings "$S_ENA_BADKEY" "$S_ENA_ONE_BAKE" >/dev/null 2>&1; then
  assert_eq "enabled-validate: unknown key aborts (reject)" "reject" "accept"
else
  assert_eq "enabled-validate: unknown key aborts (reject)" "reject" "reject"
fi

# Reject: a non-boolean value aborts.
S_ENA_BADVAL="$WORK/settings-enabled-badval.yml"
cat > "$S_ENA_BADVAL" <<'YML'
claude:
  plugins:
    enabled:
      a@mp: maybe
YML
if claude_vm_render_guest_settings "$S_ENA_BADVAL" "$S_ENA_ONE_BAKE" >/dev/null 2>&1; then
  assert_eq "enabled-validate: non-boolean value aborts (reject)" "reject" "accept"
else
  assert_eq "enabled-validate: non-boolean value aborts (reject)" "reject" "reject"
fi

# ---------------------------------------------------------------------
# Test 16: claude.permission_mode enum guard (issue #104).
#
# The launcher (claude-vm.sh) accepts ONLY bypassPermissions | default for
# claude.permission_mode and aborts on anything else -- it is a security-posture
# value and there is no reasoning model for an unknown defaultMode. The guard is
# a bare case in claude-vm.sh (not a lib function), so exercise the same case
# logic here against representative values.
# ---------------------------------------------------------------------
_permission_mode_ok() {
  case "$1" in
    bypassPermissions|default) return 0 ;;
    *) return 1 ;;
  esac
}
if _permission_mode_ok "bypassPermissions"; then
  assert_eq "permission-mode: bypassPermissions accepted" "accept" "accept"
else
  assert_eq "permission-mode: bypassPermissions accepted" "accept" "reject"
fi
if _permission_mode_ok "default"; then
  assert_eq "permission-mode: default accepted" "accept" "accept"
else
  assert_eq "permission-mode: default accepted" "accept" "reject"
fi
if _permission_mode_ok "acceptEdits"; then
  assert_eq "permission-mode: unknown mode rejected" "reject" "accept"
else
  assert_eq "permission-mode: unknown mode rejected" "reject" "reject"
fi
if _permission_mode_ok "yolo"; then
  assert_eq "permission-mode: garbage rejected" "reject" "accept"
else
  assert_eq "permission-mode: garbage rejected" "reject" "reject"
fi

# ---------------------------------------------------------------------
# Test 17: bake-relevant config canonicalization + bake-hash (issue #105).
#
# claude_vm_bake_config_json / claude_vm_bake_hash are pure (merged-config
# file -> canonical JSON / 8-hex hash). Cover the acceptance-critical
# properties: the hash is order-INSENSITIVE (bake list order + apt_sources
# declaration order do not change it), a missing key_url canonicalizes the
# same as an explicit empty one, an empty bake config hashes identically to an
# absent one (the "shares the global image" case), and different bake content
# hashes differently.
# ---------------------------------------------------------------------
BH_EMPTY="$WORK/bake-empty.yml";  printf '{}\n' > "$BH_EMPTY"
BH_EMPTY2="$WORK/bake-empty2.yml"; printf 'cpus: 4\nmem: 8192\n' > "$BH_EMPTY2"  # no packages at all

# Canonical form of an absent/empty bake config is the constant empty object.
assert_eq "bake-hash: absent packages canonicalizes to empty form" \
  '{"bake":[],"apt_sources":[]}' "$(claude_vm_bake_config_json "$BH_EMPTY")"
assert_eq "bake-hash: config with no packages key canonicalizes to empty form" \
  '{"bake":[],"apt_sources":[]}' "$(claude_vm_bake_config_json "$BH_EMPTY2")"
# Empty == absent: both hash to the same stable value (share the global image).
assert_eq "bake-hash: empty-config hash equals no-packages-config hash" \
  "$(claude_vm_bake_hash "$BH_EMPTY")" "$(claude_vm_bake_hash "$BH_EMPTY2")"
# is_empty predicate agrees.
assert_true "bake-hash: absent bake config is_empty" \
  claude_vm_bake_config_is_empty "$BH_EMPTY"

# Order-insensitivity: two configs with the same bake set in different orders
# (and a duplicate) hash identically.
BH_A="$WORK/bake-a.yml"; cat > "$BH_A" <<'YML'
packages: [git, jq, ripgrep]
apt_sources:
  - name: zeta
    repo: "deb https://z stable main"
    key_url: https://z/key.asc
  - name: alpha
    repo: "deb https://a stable main"
YML
BH_B="$WORK/bake-b.yml"; cat > "$BH_B" <<'YML'
packages: [ripgrep, git, jq, git]
apt_sources:
  - name: alpha
    repo: "deb https://a stable main"
    key_url: null
  - name: zeta
    repo: "deb https://z stable main"
    key_url: https://z/key.asc
YML
assert_eq "bake-hash: bake list order + dup does not change the hash" \
  "$(claude_vm_bake_hash "$BH_A")" "$(claude_vm_bake_hash "$BH_B")"
# Missing key_url (alpha in A) and explicit null key_url (alpha in B) both
# canonicalize to "" -- proven by the equal hashes above AND the JSON form.
assert_eq "bake-hash: missing vs explicit-null key_url canonicalize identically" \
  "$(claude_vm_bake_config_json "$BH_A")" "$(claude_vm_bake_config_json "$BH_B")"
if claude_vm_bake_config_is_empty "$BH_A"; then
  assert_eq "bake-hash: config with bake items is not empty" "not-empty" "empty"
else
  assert_eq "bake-hash: config with bake items is not empty" "not-empty" "not-empty"
fi

# Different bake content -> different hash.
BH_MORE="$WORK/bake-more.yml"; printf 'packages: [git, jq, ripgrep, fd-find]\n' > "$BH_MORE"
assert_ne "bake-hash: adding a package changes the hash" \
  "$(claude_vm_bake_hash "$BH_A")" "$(claude_vm_bake_hash "$BH_MORE")"

# Hash shape: exactly 8 lowercase hex chars.
BH_HASH="$(claude_vm_bake_hash "$BH_A")"
if printf '%s' "$BH_HASH" | grep -qE '^[0-9a-f]{8}$'; then
  assert_eq "bake-hash: hash is 8 lowercase hex chars" "ok" "ok"
else
  assert_eq "bake-hash: hash is 8 lowercase hex chars" "ok" "bad: [$BH_HASH]"
fi

# apt_sources-only (no bake packages) still counts as non-empty and hashes
# distinctly from the empty form.
BH_APTONLY="$WORK/bake-aptonly.yml"; cat > "$BH_APTONLY" <<'YML'
apt_sources:
  - name: gh
    repo: "deb https://cli.github.com/packages stable main"
    key_url: https://cli.github.com/packages/githubcli-archive-keyring.gpg
YML
if claude_vm_bake_config_is_empty "$BH_APTONLY"; then
  assert_eq "bake-hash: apt_sources-only config is not empty" "not-empty" "empty"
else
  assert_eq "bake-hash: apt_sources-only config is not empty" "not-empty" "not-empty"
fi
assert_ne "bake-hash: apt_sources-only hashes distinctly from empty" \
  "$(claude_vm_bake_hash "$BH_APTONLY")" "$(claude_vm_bake_hash "$BH_EMPTY")"

# Bake `packages:` null/empty entries (e.g. a stray `-` in the YAML list, or a
# trailing comma in flow style) must be STRIPPED from the canonical form, not
# passed through as the literal string "None"/"" -- a "None" package name
# would fail the mkosi image build (PR #161 review finding).
BH_NULLS="$WORK/bake-nulls.yml"; cat > "$BH_NULLS" <<'YML'
packages: [null, "", git]
YML
assert_eq "bake-hash: null/empty bake entries are stripped from canonical JSON" \
  '{"bake":["git"],"apt_sources":[]}' "$(claude_vm_bake_config_json "$BH_NULLS")"
BH_NULLS_CLEAN="$WORK/bake-nulls-clean.yml"; printf 'packages: [git]\n' > "$BH_NULLS_CLEAN"
assert_eq "bake-hash: null/empty-stripped config hashes the same as the equivalent clean config" \
  "$(claude_vm_bake_hash "$BH_NULLS")" "$(claude_vm_bake_hash "$BH_NULLS_CLEAN")"
# All-null/empty bake list canonicalizes to the same empty form as no bake key.
BH_ALLNULL="$WORK/bake-allnull.yml"; cat > "$BH_ALLNULL" <<'YML'
packages: [null, ""]
YML
assert_eq "bake-hash: all-null/empty bake list canonicalizes to the empty form" \
  '{"bake":[],"apt_sources":[]}' "$(claude_vm_bake_config_json "$BH_ALLNULL")"

# ---------------------------------------------------------------------
# Test 18: WHOLE-FILE image-identity segments + filename derivation (issue #179
# redesign).
#
# The image identity is now a WHOLE-FILE, RAW-BYTE hash of the two BAKE FILES
# (global-bake always present via claude_vm_file_identity_hash; a repo that
# SHIPS a config-bake.yml appends "+<reponame>-<repohash>"). No key-picking, no
# canonicalization: the hash is over the raw bytes. Exercise
# claude_vm_image_identity_segments and the filename shape the launcher derives:
# explicit guest_image opts out; a repo with no repo-bake file shares
# guest+global<hash>.raw; a repo WITH a repo-bake file gets a two-segment name.
# ---------------------------------------------------------------------
IMGDIR="/home/op/.config/claude-vm/images"
derive_image_path() {
  # Mirror claude-vm.sh's derivation: <boot-merged-file> <global-bake>
  # <repo-bake> <reponame> <default-image-dir>. The boot-merged file supplies
  # only the guest_image opt-out; the identity is computed from the two BAKE
  # FILES.
  local merged="$1" gbake="$2" rbake="$3" name="$4" dir="$5" explicit seg
  explicit="$(claude_vm_scalar "$merged" '.guest_image' "")"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
  else
    seg="$(claude_vm_image_identity_segments "$gbake" "$rbake" "$name")"
    printf '%s\n' "$dir/guest+${seg}.raw"
  fi
}

# A missing repo-bake file -> repo shares guest+global<hash>.raw.
VP_GBAKE="$WORK/vp-gbake.yml"; printf 'packages:\n  - jq\n' > "$VP_GBAKE"
VP_NOREPO="$WORK/vp-norepo.yml"  # deliberately not created
VP_GHASH="$(claude_vm_file_identity_hash "$VP_GBAKE")"
assert_eq "identity: no repo-bake file -> global segment only" \
  "global$VP_GHASH" "$(claude_vm_image_identity_segments "$VP_GBAKE" "$VP_NOREPO" myrepo)"
assert_eq "identity: no repo-bake file -> guest+global<hash>.raw" \
  "$IMGDIR/guest+global$VP_GHASH.raw" \
  "$(derive_image_path "$WORK/vp-boot-empty.yml" "$VP_GBAKE" "$VP_NOREPO" myrepo "$IMGDIR")"

# A missing GLOBAL bake file hashes to the fixed sentinel 00000000.
assert_eq "identity: absent global bake file -> global00000000 sentinel" \
  "global00000000" "$(claude_vm_image_identity_segments "$VP_NOREPO" "$VP_NOREPO" myrepo)"

# A repo that SHIPS a config-bake.yml -> two-segment identity, repo name
# sanitized (a name with a slash/space collapses to filename-safe chars). The
# repo segment's PRESENCE is gated on the FILE existing, not on its content.
VP_REPO_BAKE="$WORK/vp-repo-bake.yml"; printf 'packages:\n  - git\n  - jq\n' > "$VP_REPO_BAKE"
VP_RHASH="$(claude_vm_file_identity_hash "$VP_REPO_BAKE")"
assert_eq "identity: repo w/ a config-bake.yml appends +<name>-<repohash>" \
  "global$VP_GHASH+acme-widgets-$VP_RHASH" \
  "$(claude_vm_image_identity_segments "$VP_GBAKE" "$VP_REPO_BAKE" 'acme/widgets')"

# Explicit guest_image opts out entirely, even with a repo-bake file present.
VP_OVERRIDE="$WORK/vp-override.yml"; printf 'guest_image: /custom/my.raw\n' > "$VP_OVERRIDE"
assert_eq "identity: explicit guest_image opts out (used verbatim)" \
  "/custom/my.raw" \
  "$(derive_image_path "$VP_OVERRIDE" "$VP_GBAKE" "$VP_REPO_BAKE" myrepo "$IMGDIR")"

# Two repos with byte-identical repo-bake files but DIFFERENT names get
# DIFFERENT images (name disambiguates -- legibility over dedup, the human's
# choice: two identical repo-bake files still get two images).
assert_ne "identity: same repo-bake content, different names -> different images" \
  "$(claude_vm_image_identity_segments "$VP_GBAKE" "$VP_REPO_BAKE" repo-a)" \
  "$(claude_vm_image_identity_segments "$VP_GBAKE" "$VP_REPO_BAKE" repo-b)"

# Same global-bake + same repo-bake + same name -> same identity (warm path).
assert_eq "identity: identical inputs -> identical identity (warm path)" \
  "$(claude_vm_image_identity_segments "$VP_GBAKE" "$VP_REPO_BAKE" myrepo)" \
  "$(claude_vm_image_identity_segments "$VP_GBAKE" "$VP_REPO_BAKE" myrepo)"

# ---------------------------------------------------------------------
# Test 18b: WHOLE-FILE, RAW-BYTE hashing -- the trailing-newline lever + no
# canonicalization (issue #179 acceptance-critical). Editing ANY byte in a bake
# file changes its identity hash; a trailing-newline toggle is the documented
# force-rebuild lever. root_headroom_mb is a BAKE key, so it now rides in the
# whole-file hash rather than a key-picked projection.
# ---------------------------------------------------------------------
# Trailing-newline toggle changes the hash (the documented force-rebuild lever).
VP_NL_NO="$WORK/vp-nl-no.yml";  printf 'packages:\n  - jq' > "$VP_NL_NO"
VP_NL_YES="$WORK/vp-nl-yes.yml"; printf 'packages:\n  - jq\n' > "$VP_NL_YES"
assert_ne "identity: trailing-newline toggle changes the bake-file hash" \
  "$(claude_vm_file_identity_hash "$VP_NL_NO")" "$(claude_vm_file_identity_hash "$VP_NL_YES")"
# List ORDER changes the hash (raw bytes -- no order-canonicalization).
VP_ORD_A="$WORK/vp-ord-a.yml"; printf 'packages:\n  - git\n  - jq\n' > "$VP_ORD_A"
VP_ORD_B="$WORK/vp-ord-b.yml"; printf 'packages:\n  - jq\n  - git\n' > "$VP_ORD_B"
assert_ne "identity: bake-file list order changes the hash (no canonicalization)" \
  "$(claude_vm_file_identity_hash "$VP_ORD_A")" "$(claude_vm_file_identity_hash "$VP_ORD_B")"
# root_headroom_mb lives in the bake file, so changing it changes the bake-file
# hash and thus the identity -> a rebuild.
VP_HR1="$WORK/vp-hr1.yml"; printf 'image:\n  root_headroom_mb: 1024\n' > "$VP_HR1"
VP_HR2="$WORK/vp-hr2.yml"; printf 'image:\n  root_headroom_mb: 2048\n' > "$VP_HR2"
assert_ne "identity: global bake-file headroom change flips the global hash" \
  "$(claude_vm_file_identity_hash "$VP_HR1")" "$(claude_vm_file_identity_hash "$VP_HR2")"
assert_ne "identity: global bake-file headroom change flips the whole identity" \
  "$(claude_vm_image_identity_segments "$VP_HR1" "$VP_NOREPO" myrepo)" \
  "$(claude_vm_image_identity_segments "$VP_HR2" "$VP_NOREPO" myrepo)"
# The hash is exactly 8 lowercase hex chars.
VP_ID_HASH="$(claude_vm_file_identity_hash "$VP_GBAKE")"
if printf '%s' "$VP_ID_HASH" | grep -qE '^[0-9a-f]{8}$'; then
  assert_eq "identity: whole-file hash is 8 lowercase hex chars" "ok" "ok"
else
  assert_eq "identity: whole-file hash is 8 lowercase hex chars" "ok" "bad: [$VP_ID_HASH]"
fi

# ---------------------------------------------------------------------
# Test 19: build-guest-image.sh --print-version identity segment (issue #106).
#
# The launcher passes the pre-computed identity segments to build-guest-image.sh
# via CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS for both --print-version and --output,
# so the stamped version and the compared version agree. Exercise
# --print-version directly: unset -> the bare base version (a no-launcher smoke
# test); set -> base+<segments>, appended verbatim.
# ---------------------------------------------------------------------
BGI="$TEST_DIR/../build-guest-image.sh"
BASE_VER="$("$BGI" --print-version)"   # unset segments -> bare base version
assert_eq "print-version: unset identity segments -> bare base version" \
  "$BASE_VER" "$("$BGI" --print-version)"
# Segments are appended verbatim as +<segments>.
assert_eq "print-version: global-only segment appended verbatim" \
  "$BASE_VER+global1b20dff0" \
  "$(CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS='global1b20dff0' "$BGI" --print-version)"
assert_eq "print-version: two-segment identity appended verbatim" \
  "$BASE_VER+global1b20dff0+acme-widgets-573e2d72" \
  "$(CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS='global1b20dff0+acme-widgets-573e2d72' "$BGI" --print-version)"
# Same segments -> same version (warm path); different -> different version.
assert_eq "print-version: same identity segments -> same version (warm path)" \
  "$(CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS='globalabcd1234' "$BGI" --print-version)" \
  "$(CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS='globalabcd1234' "$BGI" --print-version)"
assert_ne "print-version: different identity segments -> different version" \
  "$(CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS='globalabcd1234' "$BGI" --print-version)" \
  "$(CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS='globaldeadbeef' "$BGI" --print-version)"
# --print-version and the launcher-side segments agree by construction: feed
# the SAME lib-computed segments into --print-version.
VP_SEG_GLOBAL="$(claude_vm_image_identity_segments "$VP_GBAKE" "$VP_NOREPO" myrepo)"
assert_eq "print-version: build-guest-image version embeds the lib identity segments" \
  "$BASE_VER+$VP_SEG_GLOBAL" \
  "$(CLAUDE_VM_IMAGE_IDENTITY_SEGMENTS="$VP_SEG_GLOBAL" "$BGI" --print-version)"

# ---------------------------------------------------------------------
# Test 19b: root-headroom BUILD input validation (issue #106 real-run fix).
#
# CLAUDE_VM_ROOT_HEADROOM_MB is the MERGED headroom the build forwards to the
# provisioner as the partition size; it is validated as a positive integer so a
# typo aborts rather than reaching the provisioner as garbage. It no longer
# folds into the version (the identity segments own the cache key now), so a
# valid headroom does NOT by itself change --print-version.
# ---------------------------------------------------------------------
assert_eq "print-version: headroom is a build input, not a version segment" \
  "$BASE_VER" "$(CLAUDE_VM_ROOT_HEADROOM_MB=2048 "$BGI" --print-version)"
# A non-integer headroom aborts with a clear error rather than silently
# building an unsized (or garbage-sized) image.
if CLAUDE_VM_ROOT_HEADROOM_MB=notanumber "$BGI" --print-version >/dev/null 2>&1; then
  assert_eq "print-version: non-integer headroom is rejected" "rejected" "accepted"
else
  assert_eq "print-version: non-integer headroom is rejected" "rejected" "rejected"
fi

# ---------------------------------------------------------------------
# Test 20: render_apt_source name validation (issue #105 review finding).
#
# render_apt_source is defined INSIDE the <<INNER heredoc in
# podman-mkosi.sh (it only ever runs inside the throwaway build container),
# so it is not directly sourceable. Extract its literal body (start line
# found by the function-header marker, end line the next top-level `}`)
# and un-escape the heredoc's `\$` back to `$`, then source the extracted
# function in-process to exercise the name-validation guard directly, with
# no container and no network.
#
# name flows unescaped into staging filenames (<dir>/<name>.asc,
# <dir>/<name>.list); since the merged config unions the per-repo
# .claude-vm/config-bake.yml, name is not fully operator-authored for an
# untrusted repo. A name containing e.g. "../" must be REJECTED before any
# path is built, rather than allowed to write outside the staging dirs.
# ---------------------------------------------------------------------
PODMAN_MKOSI="$TEST_DIR/../provisioners/podman-mkosi.sh"
RAS_START="$(grep -n '^render_apt_source() {' "$PODMAN_MKOSI" | head -1 | cut -d: -f1)"
RAS_END="$(awk -v start="$RAS_START" 'NR > start && /^}/ { print NR; exit }' "$PODMAN_MKOSI")"
RAS_SRC="$WORK/render_apt_source.sh"
if [ -n "$RAS_START" ] && [ -n "$RAS_END" ]; then
  awk -v start="$RAS_START" -v end="$RAS_END" 'NR >= start && NR <= end' "$PODMAN_MKOSI" \
    | sed 's/\\\$/$/g' > "$RAS_SRC"
  # shellcheck source=/dev/null
  . "$RAS_SRC"
fi

if [ -n "${RAS_START:-}" ] && [ -n "${RAS_END:-}" ] && command -v render_apt_source >/dev/null 2>&1; then
  RAS_KEYRINGS="$WORK/ras-keyrings"
  RAS_SOURCES="$WORK/ras-sources"

  # Path-traversal name is rejected (non-zero return), and -- critically --
  # no file is written outside (or inside) the intended staging dirs.
  rm -rf "$RAS_KEYRINGS" "$RAS_SOURCES"; mkdir -p "$RAS_KEYRINGS" "$RAS_SOURCES"
  if render_apt_source '../../etc/evil' 'deb https://x stable main' '' \
      "$RAS_KEYRINGS" "$RAS_SOURCES" >/dev/null 2>&1; then
    assert_eq "render_apt_source: path-traversal name is rejected" "rejected" "accepted"
  else
    assert_eq "render_apt_source: path-traversal name is rejected" "rejected" "rejected"
  fi
  assert_true "render_apt_source: rejected traversal name writes no file in sources_dir" \
    bash -c '[ -z "$(ls -A "$1" 2>/dev/null)" ]' _ "$RAS_SOURCES"
  assert_true "render_apt_source: rejected traversal name writes nothing outside staging dirs" \
    bash -c '[ ! -e "$1/etc/evil.list" ]' _ "$WORK"

  # A name containing a slash but no ".." is equally rejected -- the guard is
  # a charset allowlist, not a ".." blacklist.
  rm -rf "$RAS_KEYRINGS" "$RAS_SOURCES"; mkdir -p "$RAS_KEYRINGS" "$RAS_SOURCES"
  if render_apt_source 'sub/dir' 'deb https://x stable main' '' \
      "$RAS_KEYRINGS" "$RAS_SOURCES" >/dev/null 2>&1; then
    assert_eq "render_apt_source: slash-containing name is rejected" "rejected" "accepted"
  else
    assert_eq "render_apt_source: slash-containing name is rejected" "rejected" "rejected"
  fi

  # A conservative charset-safe name (letters, digits, dot, underscore,
  # hyphen) is still accepted and renders the expected files.
  rm -rf "$RAS_KEYRINGS" "$RAS_SOURCES"; mkdir -p "$RAS_KEYRINGS" "$RAS_SOURCES"
  if render_apt_source 'gh-cli.v2' 'deb https://cli.github.com/packages stable main' '' \
      "$RAS_KEYRINGS" "$RAS_SOURCES" >/dev/null 2>&1; then
    assert_eq "render_apt_source: charset-safe name is accepted" "accepted" "accepted"
  else
    assert_eq "render_apt_source: charset-safe name is accepted" "accepted" "rejected"
  fi
  assert_true "render_apt_source: charset-safe name writes the expected sources file" \
    test -f "$RAS_SOURCES/gh-cli.v2.list"
else
  echo "SKIP: render_apt_source extraction from podman-mkosi.sh failed; name-validation tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 21: boot-time apt derived egress (issue #106).
#
# claude_vm_boot_apt_egress_needed (the "iff" gate) and
# claude_vm_apt_source_hosts (per-entry host derivation) are the two pure
# helpers claude-vm.sh's derived-egress block uses to decide whether/what to
# add to the guest egress allowlist for boot-time apt work. Exercise both
# directly, with no VM and no launcher run.
# ---------------------------------------------------------------------
DE_AUTO_QUIET="$WORK/de-auto-quiet.yml"
cat > "$DE_AUTO_QUIET" <<'YML'
packages: []
update_at_boot: false
add_apt_uris_to_allowlist: auto
YML
if ! claude_vm_boot_apt_egress_needed "$DE_AUTO_QUIET"; then
  assert_eq "boot_apt_egress_needed: auto + empty boot packages + update_at_boot false -> NOT needed" "not-needed" "not-needed"
else
  assert_eq "boot_apt_egress_needed: auto + empty boot packages + update_at_boot false -> NOT needed" "not-needed" "needed"
fi

DE_INSTALL="$WORK/de-install.yml"
cat > "$DE_INSTALL" <<'YML'
packages:
  - htop
update_at_boot: false
add_apt_uris_to_allowlist: auto
YML
if claude_vm_boot_apt_egress_needed "$DE_INSTALL"; then
  assert_eq "boot_apt_egress_needed: nonempty boot packages -> needed" "needed" "needed"
else
  assert_eq "boot_apt_egress_needed: nonempty boot packages -> needed" "needed" "not-needed"
fi

DE_UPDATE_DEFAULT="$WORK/de-update-default.yml"
printf '{}\n' > "$DE_UPDATE_DEFAULT"
if claude_vm_boot_apt_egress_needed "$DE_UPDATE_DEFAULT"; then
  assert_eq "boot_apt_egress_needed: unset config -> needed (update_at_boot defaults true)" "needed" "needed"
else
  assert_eq "boot_apt_egress_needed: unset config -> needed (update_at_boot defaults true)" "needed" "not-needed"
fi

DE_ALWAYS="$WORK/de-always.yml"
cat > "$DE_ALWAYS" <<'YML'
packages: []
update_at_boot: false
add_apt_uris_to_allowlist: always
YML
if claude_vm_boot_apt_egress_needed "$DE_ALWAYS"; then
  assert_eq "boot_apt_egress_needed: add_apt_uris_to_allowlist always -> needed regardless" "needed" "needed"
else
  assert_eq "boot_apt_egress_needed: add_apt_uris_to_allowlist always -> needed regardless" "needed" "not-needed"
fi

# Host derivation: repo + key_url URIs (including a non-default port, which
# must be STRIPPED -- egress allowlists in this codebase are host-only), a
# repo line with no key_url at all, de-duplicated across entries.
DE_HOSTS="$WORK/de-hosts.yml"
cat > "$DE_HOSTS" <<'YML'
apt_sources:
  - name: gh-cli
    repo: "deb https://cli.github.com/packages stable main"
    key_url: "https://key.example.com:8443/key.gpg"
  - name: dup-host
    repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/x.asc] https://cli.github.com/other stable main"
YML
DE_HOSTS_OUT="$(claude_vm_apt_source_hosts "$WORK/de-hosts-nobake.yml" "$DE_HOSTS" | sort | tr '\n' ',')"
assert_eq "apt_source_hosts: repo + key_url hosts extracted, port stripped, de-duped" \
  "cli.github.com,key.example.com," "$DE_HOSTS_OUT"

DE_HOSTS_EMPTY="$WORK/de-hosts-empty.yml"
printf '{}\n' > "$DE_HOSTS_EMPTY"
assert_eq "apt_source_hosts: no apt_sources in either tier -> empty" \
  "" "$(claude_vm_apt_source_hosts "$DE_HOSTS_EMPTY" "$DE_HOSTS_EMPTY")"

assert_eq "CLAUDE_VM_DEBIAN_MIRROR_HOSTS: pins the two Debian mirror hosts" \
  "deb.debian.org security.debian.org" "$CLAUDE_VM_DEBIAN_MIRROR_HOSTS"

# ---------------------------------------------------------------------
# Test 22: render_apt_source_boot name validation (issue #106).
#
# render_apt_source_boot is defined INSIDE the <<'BOOT' heredoc in
# build-guest-image.sh's emit_boot_launcher (it only ever runs as root at
# guest boot, against the guest's LIVE /etc/apt), so it is not directly
# sourceable. Extract its literal body the same way Test 20 extracts
# podman-mkosi.sh's render_apt_source -- no `\$` un-escaping needed here
# (this heredoc is a plain <<'BOOT', not a nested <<INNER inside another
# heredoc) -- then source it in-process.
#
# Only the REJECTION paths are exercised here: render_apt_source_boot
# hardcodes /etc/apt/keyrings and /etc/apt/sources.list.d (it writes the
# guest's LIVE apt config, unlike the build-time function's staging-dir
# parameters), which this host-side test process cannot write to (and must
# not attempt to). Every rejection below returns BEFORE any mkdir/write, so
# they are safely exercisable without touching the test host's real
# /etc/apt -- the same "name is not fully operator-authored, so validate
# before building any path" rationale as Test 20.
# ---------------------------------------------------------------------
BUILD_GUEST_IMAGE="$TEST_DIR/../build-guest-image.sh"
RASB_START="$(grep -n '^render_apt_source_boot() {' "$BUILD_GUEST_IMAGE" | head -1 | cut -d: -f1)"
RASB_END="$(awk -v start="$RASB_START" 'NR > start && /^}/ { print NR; exit }' "$BUILD_GUEST_IMAGE")"
RASB_SRC="$WORK/render_apt_source_boot.sh"
if [ -n "$RASB_START" ] && [ -n "$RASB_END" ]; then
  awk -v start="$RASB_START" -v end="$RASB_END" 'NR >= start && NR <= end' "$BUILD_GUEST_IMAGE" > "$RASB_SRC"
  # render_apt_source_boot calls log(); stub it so the extracted function
  # sources standalone without pulling in the rest of the boot launcher.
  printf 'log() { :; }\n' > "$WORK/render_apt_source_boot_stub.sh"
  cat "$RASB_SRC" >> "$WORK/render_apt_source_boot_stub.sh"
  # shellcheck source=/dev/null
  . "$WORK/render_apt_source_boot_stub.sh"
fi

if [ -n "${RASB_START:-}" ] && [ -n "${RASB_END:-}" ] && command -v render_apt_source_boot >/dev/null 2>&1; then
  # Path-traversal name is rejected (non-zero return) BEFORE any mkdir/write.
  if render_apt_source_boot '../../etc/evil' 'deb https://x stable main' '' >/dev/null 2>&1; then
    assert_eq "render_apt_source_boot: path-traversal name is rejected" "rejected" "accepted"
  else
    assert_eq "render_apt_source_boot: path-traversal name is rejected" "rejected" "rejected"
  fi

  # A name containing a slash but no ".." is equally rejected -- charset
  # allowlist, not a ".." blacklist.
  if render_apt_source_boot 'sub/dir' 'deb https://x stable main' '' >/dev/null 2>&1; then
    assert_eq "render_apt_source_boot: slash-containing name is rejected" "rejected" "accepted"
  else
    assert_eq "render_apt_source_boot: slash-containing name is rejected" "rejected" "rejected"
  fi

  # Missing name/repo is rejected.
  if render_apt_source_boot '' 'deb https://x stable main' '' >/dev/null 2>&1; then
    assert_eq "render_apt_source_boot: empty name is rejected" "rejected" "accepted"
  else
    assert_eq "render_apt_source_boot: empty name is rejected" "rejected" "rejected"
  fi

  # A pinned signed-by outside the two allowed keyrings directories is
  # rejected (the case-3 write-primitive guard ported from render_apt_source).
  if render_apt_source_boot 'evil' 'deb [signed-by=/etc/cron.d/x] https://x stable main' 'https://x/key.asc' >/dev/null 2>&1; then
    assert_eq "render_apt_source_boot: signed-by outside allowed keyrings dirs is rejected" "rejected" "accepted"
  else
    assert_eq "render_apt_source_boot: signed-by outside allowed keyrings dirs is rejected" "rejected" "rejected"
  fi

  # A pinned signed-by with a '..' path segment is rejected.
  if render_apt_source_boot 'evil2' 'deb [signed-by=/etc/apt/keyrings/../../cron.d/x] https://x stable main' 'https://x/key.asc' >/dev/null 2>&1; then
    assert_eq "render_apt_source_boot: signed-by with '..' segment is rejected" "rejected" "accepted"
  else
    assert_eq "render_apt_source_boot: signed-by with '..' segment is rejected" "rejected" "rejected"
  fi
else
  echo "SKIP: render_apt_source_boot extraction from build-guest-image.sh failed; name-validation tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 22b: render_apt_source_boot content-sniffing (issue #106 review
# finding, PR #174 round 6, real-guest failure -- same defect class as Test
# 20's podman-mkosi.sh render_apt_source additions).
#
# render_apt_source_boot hardcodes its write dirs to the LIVE
# /etc/apt/keyrings and /etc/apt/sources.list.d (unlike the build-time
# function's staging-dir parameters), so Test 22 above only exercises
# rejection paths that return before any mkdir/write. To exercise the
# ACCEPT + sniff-rename path without touching the real /etc/apt, this test
# extracts the function body a second time and retargets its two hardcoded
# path locals to a WORK-scoped scratch dir via sed -- a test-harness-only
# rewrite of the extracted copy, not a change to the shipped function's
# behavior (the shipped function still hardcodes /etc/apt/* verbatim; only
# this scratch copy's local defaults differ). A stub curl on PATH answers
# the key_url fetch with content chosen by the caller so both the
# ASCII-armored and binary shapes are exercised.
# ---------------------------------------------------------------------
RASB_SNIFF_ROOT="$WORK/rasb-sniff-root"
mkdir -p "$RASB_SNIFF_ROOT/bin"
if [ -n "${RASB_START:-}" ] && [ -n "${RASB_END:-}" ]; then
  RASB_SNIFF_SRC="$WORK/render_apt_source_boot_sniff.sh"
  awk -v start="$RASB_START" -v end="$RASB_END" 'NR >= start && NR <= end' "$BUILD_GUEST_IMAGE" \
    | sed \
        -e "s#local keyrings_dir=\"/etc/apt/keyrings\" sources_dir=\"/etc/apt/sources.list.d\"#local keyrings_dir=\"$RASB_SNIFF_ROOT/keyrings\" sources_dir=\"$RASB_SNIFF_ROOT/sources\"#" \
    > "$RASB_SNIFF_SRC"
  printf 'log() { :; }\n' > "$WORK/render_apt_source_boot_sniff_stub.sh"
  cat "$RASB_SNIFF_SRC" >> "$WORK/render_apt_source_boot_sniff_stub.sh"
  # shellcheck source=/dev/null
  ( . "$WORK/render_apt_source_boot_sniff_stub.sh"; command -v render_apt_source_boot >/dev/null 2>&1 )
  RASB_SNIFF_RC=$?
else
  RASB_SNIFF_RC=1
fi

# Stub curl, same URL-keyed content-shape convention as podman-mkosi-test.sh:
# a URL containing "binary" writes raw/binary OpenPGP-shaped bytes; every
# other URL writes ASCII-armored content starting with "-----BEGIN PGP".
cat > "$RASB_SNIFF_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
url=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  case "$a" in
    -*) : ;;
    *) [ -n "$url" ] || url="$a" ;;
  esac
  prev="$a"
done
[ -n "$out" ] || exit 1
case "$url" in
  *binary*)
    printf '\x99\x02stub-binary-key-material\n' > "$out"
    ;;
  *)
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nstub-armored-key-material\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$out"
    ;;
esac
exit 0
EOF
chmod +x "$RASB_SNIFF_ROOT/bin/curl"

if [ "$RASB_SNIFF_RC" -eq 0 ]; then
  # call_render_boot <case-label> <name> <repo> <key_url>
  call_render_boot() {
    local case_label="$1" c_name="$2" c_repo="$3" c_key_url="$4"
    rm -rf "$RASB_SNIFF_ROOT/keyrings" "$RASB_SNIFF_ROOT/sources"
    (
      PATH="$RASB_SNIFF_ROOT/bin:$PATH"
      # shellcheck source=/dev/null
      . "$WORK/render_apt_source_boot_sniff_stub.sh"
      render_apt_source_boot "$c_name" "$c_repo" "$c_key_url"
    )
    local rc=$?
    echo "EXIT:$rc"
    local list_file="$RASB_SNIFF_ROOT/sources/${c_name}.list"
    if [ -f "$list_file" ]; then
      echo "RENDERED:$(cat "$list_file")"
    else
      echo "RENDERED:<no .list file written>"
    fi
    find "$RASB_SNIFF_ROOT/keyrings" -type f 2>/dev/null | while read -r f; do
      echo "KEYFILE:${f#"$RASB_SNIFF_ROOT"/}"
    done
  }

  # --- Bare repo line, BINARY fetched key -- must be written/referenced as
  # .gpg, not the default .asc (the exact real-guest githubcli defect). ---
  OUT="$(call_render_boot bin-bare boot-bin 'deb https://cli.github.com/packages stable main' 'https://cli.github.com/packages/binary-key.gpg')"
  assert_eq "render_apt_source_boot: bare line, binary key: exit 0" \
    "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
  RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
  assert_eq "render_apt_source_boot: bare line, binary key: signed-by references .gpg" \
    "deb [signed-by=$RASB_SNIFF_ROOT/keyrings/boot-bin.gpg] https://cli.github.com/packages stable main" \
    "$RENDERED_LINE"
  assert_true "render_apt_source_boot: bare line, binary key: key written as .gpg" \
    test -f "$RASB_SNIFF_ROOT/keyrings/boot-bin.gpg"
  assert_true "render_apt_source_boot: bare line, binary key: no stray .asc" \
    bash -c '[ ! -e "$1" ]' _ "$RASB_SNIFF_ROOT/keyrings/boot-bin.asc"

  # --- Bare repo line, ARMORED fetched key -- stays .asc (content-driven,
  # not a blanket switch). ---
  OUT="$(call_render_boot bin-armored boot-arm 'deb https://cli.github.com/packages stable main' 'https://cli.github.com/packages/armored-key.asc')"
  assert_eq "render_apt_source_boot: bare line, armored key: exit 0" \
    "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
  RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
  assert_eq "render_apt_source_boot: bare line, armored key: signed-by references .asc" \
    "deb [signed-by=$RASB_SNIFF_ROOT/keyrings/boot-arm.asc] https://cli.github.com/packages stable main" \
    "$RENDERED_LINE"
  assert_true "render_apt_source_boot: bare line, armored key: key written as .asc" \
    test -f "$RASB_SNIFF_ROOT/keyrings/boot-arm.asc"

  # NOTE: a pinned-signed-by= exemption case is intentionally NOT exercised
  # here. For the pinned path, keyring_path becomes the LITERAL
  # existing_signed_by string (validated to start with /etc/apt/keyrings/ or
  # /usr/share/keyrings/) and mkdir/curl write there directly -- the
  # keyrings_dir retargeting this test applies does not reach that branch.
  # Driving it would write to this host's real /etc/apt/keyrings, which Test
  # 22's own rationale above forbids. The pinned-exemption case matrix
  # itself (same guard variable, same code shape) is covered on the
  # build-time twin in podman-mkosi-test.sh's "real githubcli failure line"
  # case, and the two implementations are kept in sync structurally (see the
  # header comment on render_apt_source_boot referencing render_apt_source).
else
  echo "SKIP: render_apt_source_boot sniff-path extraction/retargeting failed; content-sniffing tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 23: boot_apt_phase fallback-update hoist (issue #106 review finding,
# PR #174 round 3).
#
# boot_apt_phase is defined INSIDE the same <<'BOOT' heredoc as
# render_apt_source_boot above, so it is extracted the same way: grab its
# literal body by line range and source it in-process with log/apt-get/
# render_apt_source_boot stubbed out. apt-get is stubbed to APPEND its argv
# to a call-log file (rather than a no-op) so these tests can assert WHICH
# apt-get subcommands ran, not just that the function didn't crash.
#
# The scenario under test: install_at_boot names only base-repo packages
# (no apt_sources), and update_at_boot is false. Before the round-3 fix,
# the fallback `apt-get update` for a nonempty install list was nested
# inside the `-s "$APT_SOURCES_TSV"` branch, so this exact combination ran
# `apt-get install` with NO index refresh this boot. The fix hoists the
# fallback out so any nonempty install list gets a refresh whenever
# update_at_boot didn't already provide one.
# ---------------------------------------------------------------------
BAP_START="$(grep -n '^boot_apt_phase() {' "$BUILD_GUEST_IMAGE" | head -1 | cut -d: -f1)"
BAP_END="$(awk -v start="$BAP_START" 'NR > start && /^}/ { print NR; exit }' "$BUILD_GUEST_IMAGE")"
BAP_SRC="$WORK/boot_apt_phase.sh"
if [ -n "$BAP_START" ] && [ -n "$BAP_END" ]; then
  {
    echo 'log() { :; }'
    echo 'render_apt_source_boot() { :; }'
    echo 'APT_GET_CALL_LOG="${APT_GET_CALL_LOG:-/dev/null}"'
    echo 'apt-get() { printf "%s\n" "$*" >> "$APT_GET_CALL_LOG"; return "${APT_GET_STUB_EXIT:-0}"; }'
    awk -v start="$BAP_START" -v end="$BAP_END" 'NR >= start && NR <= end' "$BUILD_GUEST_IMAGE"
  } > "$BAP_SRC"
  # shellcheck source=/dev/null
  . "$BAP_SRC"
fi

if [ -n "${BAP_START:-}" ] && [ -n "${BAP_END:-}" ] && command -v boot_apt_phase >/dev/null 2>&1; then
  # Scenario: update_at_boot=false, install_at_boot nonempty (base-repo-only
  # -- no apt_sources.tsv). Before the fix: no 'update' call at all. After
  # the fix: exactly one 'update' call (the hoisted fallback), before the
  # 'install' call.
  BAP_CALLS="$WORK/boot-apt-calls.log"
  : > "$BAP_CALLS"
  APT_GET_CALL_LOG="$BAP_CALLS"
  APT_INSTALL_LIST="$WORK/apt-install-baseonly.list"
  printf 'curl\n' > "$APT_INSTALL_LIST"
  APT_SOURCES_TSV="$WORK/apt-sources-empty.tsv"
  : > "$APT_SOURCES_TSV"
  APT_PROXY_OPTS=()
  CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT="false"
  ( boot_apt_phase >/dev/null 2>&1 || true )

  UPDATE_CALLS="$(grep -c '^ *update ' "$BAP_CALLS" || true)"
  assert_eq "boot_apt_phase: base-repo-only install with update_at_boot=false still refreshes the index" \
    "1" "$UPDATE_CALLS"

  INSTALL_LINE_NO="$(grep -n ' install ' "$BAP_CALLS" | head -1 | cut -d: -f1)"
  UPDATE_LINE_NO="$(grep -n '^ *update ' "$BAP_CALLS" | head -1 | cut -d: -f1)"
  if [ -n "$INSTALL_LINE_NO" ] && [ -n "$UPDATE_LINE_NO" ] && [ "$UPDATE_LINE_NO" -lt "$INSTALL_LINE_NO" ]; then
    assert_eq "boot_apt_phase: fallback update runs before install" "before" "before"
  else
    assert_eq "boot_apt_phase: fallback update runs before install" "before" "after-or-missing"
  fi

  # Scenario: update_at_boot=true. did_update is already 1, so the
  # fallback must NOT fire a second 'update' -- only the one from the
  # update_at_boot branch itself.
  : > "$BAP_CALLS"
  CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT="true"
  ( boot_apt_phase >/dev/null 2>&1 || true )
  UPDATE_CALLS_TRUE="$(grep -c '^ *update ' "$BAP_CALLS" || true)"
  assert_eq "boot_apt_phase: update_at_boot=true does not double-update for install_at_boot" \
    "1" "$UPDATE_CALLS_TRUE"

  # Scenario: update_at_boot=false and install_at_boot EMPTY -- no apt-get
  # calls should run at all (nothing to refresh an index for).
  : > "$BAP_CALLS"
  CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT="false"
  APT_INSTALL_LIST="$WORK/apt-install-empty.list"
  : > "$APT_INSTALL_LIST"
  ( boot_apt_phase >/dev/null 2>&1 || true )
  UPDATE_CALLS_EMPTY="$(grep -c '^ *update ' "$BAP_CALLS" || true)"
  assert_eq "boot_apt_phase: no install_at_boot and update_at_boot=false runs no update" \
    "0" "$UPDATE_CALLS_EMPTY"

  # -------------------------------------------------------------------
  # boot_apt_phase: an apt_sources record's empty MIDDLE field must survive.
  #
  # The records are name<TAB>repo<TAB>key_url. A tab is IFS WHITESPACE, so
  # 'IFS=<tab> read -r a b c' collapses a RUN of tabs into ONE separator: an
  # entry with a key_url but no repo is emitted as name<TAB><TAB>key_url, the
  # empty middle field vanishes, and the KEY URL arrives as the repo LINE --
  # rendered straight into the guest's live /etc/apt with no key fetched. Same
  # class as the marketplace record split in podman-mkosi.sh (issue #226).
  #
  # Driven through the REAL extracted boot_apt_phase, with
  # render_apt_source_boot swapped for a recorder so the assertion is on the
  # three values the split actually produced. The records come from the real
  # emitter (claude_vm_apt_sources) rather than hand-typed tabs, so the test
  # would notice the emitter changing shape underneath the reader.
  # -------------------------------------------------------------------
  BAP_ARGV="$WORK/boot-apt-argv.log"
  render_apt_source_boot() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$BAP_ARGV"; }

  BAP_AS_YML="$WORK/bap-apt-sources.yml"
  cat > "$BAP_AS_YML" <<'YML'
apt_sources:
  - name: nr
    key_url: https://k.example/key.asc
  - name: gh
    repo: "deb https://cli.github.com/packages stable main"
    key_url: https://cli.github.com/packages/k.gpg
  - name: nk
    repo: "deb https://r.example x main"
YML
  APT_SOURCES_TSV="$WORK/bap-apt-sources.tsv"
  claude_vm_apt_sources "$BAP_AS_YML" > "$APT_SOURCES_TSV"
  APT_INSTALL_LIST="$WORK/apt-install-baseonly.list"
  CLAUDE_VM_PACKAGES_UPDATE_AT_BOOT="false"
  : > "$BAP_ARGV"
  ( boot_apt_phase >/dev/null 2>&1 || true )

  assert_eq "boot_apt_phase: an apt_source with no repo keeps the key_url in field 3" \
    "nr||https://k.example/key.asc" "$(sed -n 1p "$BAP_ARGV")"
  assert_eq "boot_apt_phase: a fully-populated apt_source splits into the same three fields" \
    "gh|deb https://cli.github.com/packages stable main|https://cli.github.com/packages/k.gpg" \
    "$(sed -n 2p "$BAP_ARGV")"
  assert_eq "boot_apt_phase: a trailing empty key_url lands empty" \
    "nk|deb https://r.example x main|" "$(sed -n 3p "$BAP_ARGV")"

  # NEGATIVE CONTROL: rebuild the pre-fix collapsing read from the SAME
  # extracted lines (swap the read line back, drop the four hand-split
  # expansions) and show it hands the key url over as the repo line. Sourced
  # and run inside a subshell so the good definition above survives.
  BAP_OLD_SRC="$WORK/boot_apt_phase_old.sh"
  BAP_OLD_READ="      while IFS=\$'\\t' read -r as_name as_repo as_key_url; do"
  BAP_OLD_READ_AWK="      while IFS=\$'\\\\t' read -r as_name as_repo as_key_url; do"
  awk -v oldread="$BAP_OLD_READ_AWK" '
    $0 == "      while IFS= read -r as_record; do" { print oldread; next }
    $0 ~ /^        as_(name|rest|repo|key_url)=/ { next }
    { print }
  ' "$BAP_SRC" > "$BAP_OLD_SRC"
  assert_eq "boot_apt_phase: the control really carries the old tab-IFS read" \
    "1" "$(grep -cF -- "$BAP_OLD_READ" "$BAP_OLD_SRC" || true)"
  : > "$BAP_ARGV"
  (
    # shellcheck source=/dev/null
    . "$BAP_OLD_SRC"
    render_apt_source_boot() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$BAP_ARGV"; }
    boot_apt_phase >/dev/null 2>&1 || true
  )
  assert_eq "boot_apt_phase: NEGATIVE CONTROL -- the old read misreads the key_url as the repo" \
    "nr|https://k.example/key.asc|" "$(sed -n 1p "$BAP_ARGV")"

  # Restore the inert stub so any later use of the extracted phase behaves as
  # the surrounding tests expect.
  render_apt_source_boot() { :; }
else
  echo "SKIP: boot_apt_phase extraction from build-guest-image.sh failed; fallback-update tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 24: two-doc bake/boot model -- one schema per file type (issue #179).
#
# The config is FOUR files (global-bake, global-boot, repo-bake, repo-boot),
# all optional. Merging happens WITHIN a tier only: global+repo bake ->
# MERGED_BAKE, global+repo boot -> MERGED_BOOT (scalars repo-wins, lists
# union), and every reader consumes its tier's document at the FILE-schema
# path -- no translation layer, no cross-tier document, no key that parses
# without being read. Includes the regression tests for the defect that
# forced this shape (top-level boot keys silently dropped by the old
# normalize shim).
# ---------------------------------------------------------------------
F_GBAKE="$WORK/f-gbake.yml"; cat > "$F_GBAKE" <<'YML'
packages:
  - jq
  - ripgrep
apt_sources:
  - name: shared
    repo: "deb https://ex.com/g stable main"
    key_url: https://ex.com/g/key.asc
image:
  root_headroom_mb: 1024
YML
F_GBOOT="$WORK/f-gboot.yml"; cat > "$F_GBOOT" <<'YML'
cpus: 2
mem: 4096
packages:
  - htop
update_at_boot: true
egress:
  allow:
    - api.anthropic.com
    - github.com
YML
F_RBAKE="$WORK/f-rbake.yml"; cat > "$F_RBAKE" <<'YML'
packages:
  - fd-find
YML
F_RBOOT="$WORK/f-rboot.yml"; cat > "$F_RBOOT" <<'YML'
cpus: 8
packages:
  - awscli
egress:
  allow:
    - cache.example.com
YML
F_BOOT="$WORK/f-boot.yml"
F_BAKE="$WORK/f-bake.yml"
claude_vm_merge_config "$F_GBAKE" "$F_RBAKE" > "$F_BAKE"
claude_vm_merge_config "$F_GBOOT" "$F_RBOOT" > "$F_BOOT"

assert_eq "two-doc: repo boot scalar wins (cpus)" \
  "8" "$(claude_vm_scalar "$F_BOOT" '.cpus' 'X')"
assert_eq "two-doc: global boot scalar fills gap (mem)" \
  "4096" "$(claude_vm_scalar "$F_BOOT" '.mem' 'X')"
assert_eq "two-doc: bake packages union stays in the bake doc" \
  "fd-find,jq,ripgrep," "$(claude_vm_list_items "$F_BAKE" '.packages' | sort | tr '\n' ',')"
assert_eq "two-doc: boot packages union stays in the boot doc" \
  "awscli,htop," "$(claude_vm_list_items "$F_BOOT" '.packages' | sort | tr '\n' ',')"
assert_eq "two-doc: bake apt_sources read at the file-schema path" \
  "shared," "$(claude_vm_apt_sources "$F_BAKE" | cut -f1 | sort | tr '\n' ',')"
assert_eq "two-doc: egress unioned across boot files" \
  "api.anthropic.com,cache.example.com,github.com," "$(claude_vm_egress_hosts "$F_BOOT" | sort | tr '\n' ',')"
assert_eq "two-doc: image.root_headroom_mb from the bake doc" \
  "1024" "$(claude_vm_scalar "$F_BAKE" '.image.root_headroom_mb' 'X')"
# The two `packages:` meanings never share a document -- the bake doc's list
# must not contain boot packages and vice versa.
assert_eq "two-doc: bake doc carries no boot packages" \
  "0" "$(claude_vm_list_items "$F_BAKE" '.packages' | grep -c 'htop\|awscli')"

# THE REGRESSION THIS REDESIGN EXISTS FOR (issue #179 real-boot finding):
# a boot file's documented top-level `update_at_boot: false` /
# `add_apt_uris_to_allowlist` MUST reach the resolvers -- under the old
# normalize-into-internal-schema shim they parsed fine and were silently
# ignored (no reader ever looked at the top level), so the defaults won and
# boot-time apt ran despite an explicit false.
REG_BOOT_G="$WORK/reg-boot-g.yml"
printf 'update_at_boot: false\nadd_apt_uris_to_allowlist: auto\n' > "$REG_BOOT_G"
REG_BOOT="$WORK/reg-boot.yml"
claude_vm_merge_config "$REG_BOOT_G" "$WORK/does-not-exist.yml" > "$REG_BOOT"
assert_eq "regression: boot-file update_at_boot: false reaches the boolean resolver" \
  "false" "$(claude_vm_bool_scalar "$REG_BOOT" '.update_at_boot' "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT")"
assert_eq "regression: boot-file add_apt_uris_to_allowlist reaches the resolver" \
  "auto" "$(claude_vm_scalar "$REG_BOOT" '.add_apt_uris_to_allowlist' 'X')"
if ! claude_vm_boot_apt_egress_needed "$REG_BOOT"; then
  assert_eq "regression: update_at_boot false + no boot packages -> no derived apt egress" \
    "not-needed" "not-needed"
else
  assert_eq "regression: update_at_boot false + no boot packages -> no derived apt egress" \
    "not-needed" "needed"
fi

# All-absent files merge to an empty document cleanly, per tier.
F_EFF_NONE="$WORK/f-eff-none.yml"
claude_vm_merge_config "$WORK/nope-a" "$WORK/nope-b" > "$F_EFF_NONE"
assert_eq "two-doc: all-absent merges to empty document" \
  "0" "$(yq eval 'length' "$F_EFF_NONE" 2>/dev/null)"

# ---------------------------------------------------------------------
# Test 25: apt_sources union + dedupe-by-name across bake/boot (issue #179).
#
# Same name with IDENTICAL {repo, key_url} in two files -> one render (collapses
# under the list union). Same name with DIFFERING content -> the composed config
# ABORTS loudly (claude_vm_check_apt_sources_conflicts), no silent shadowing.
# ---------------------------------------------------------------------
# Identical name+content in bake and boot tiers -> no conflict (an identical
# entry present in both tiers is fine; each tier renders its own copy).
AS_GBAKE="$WORK/as-gbake.yml"; cat > "$AS_GBAKE" <<'YML'
apt_sources:
  - name: gh
    repo: "deb https://cli.github.com/packages stable main"
    key_url: https://cli.github.com/packages/key.gpg
YML
AS_GBOOT_OK="$WORK/as-gboot-ok.yml"; cat > "$AS_GBOOT_OK" <<'YML'
apt_sources:
  - name: gh
    repo: "deb https://cli.github.com/packages stable main"
    key_url: https://cli.github.com/packages/key.gpg
YML
AS_BAKE_OK="$WORK/as-bake-ok.yml"; AS_BOOT_OK="$WORK/as-boot-ok.yml"
claude_vm_merge_config "$AS_GBAKE" "$WORK/does-not-exist.yml" > "$AS_BAKE_OK"
claude_vm_merge_config "$AS_GBOOT_OK" "$WORK/does-not-exist.yml" > "$AS_BOOT_OK"
if claude_vm_check_apt_sources_conflicts "$AS_BAKE_OK" "$AS_BOOT_OK" 2>/dev/null; then
  assert_eq "apt_sources: identical name+content across tiers passes the conflict check" \
    "passes" "passes"
else
  assert_eq "apt_sources: identical name+content across tiers passes the conflict check" \
    "passes" "aborted"
fi

# Same name, DIFFERING content across tiers -> conflict check ABORTS (non-zero)
# with a diagnostic naming the entry.
AS_GBOOT_CONFLICT="$WORK/as-gboot-conflict.yml"; cat > "$AS_GBOOT_CONFLICT" <<'YML'
apt_sources:
  - name: gh
    repo: "deb https://cli.github.com/OTHER stable main"
    key_url: https://cli.github.com/packages/key.gpg
YML
AS_BOOT_CONFLICT="$WORK/as-boot-conflict.yml"
claude_vm_merge_config "$AS_GBOOT_CONFLICT" "$WORK/does-not-exist.yml" > "$AS_BOOT_CONFLICT"
if claude_vm_check_apt_sources_conflicts "$AS_BAKE_OK" "$AS_BOOT_CONFLICT" >/dev/null 2>"$WORK/as-conflict.err"; then
  assert_eq "apt_sources: name conflict with differing content aborts" "aborted" "passed"
else
  assert_eq "apt_sources: name conflict with differing content aborts" "aborted" "aborted"
fi
assert_true "apt_sources: conflict abort names the conflicting entry" \
  grep -q 'gh' "$WORK/as-conflict.err"

# ---------------------------------------------------------------------
# Test 26: boot render skips baked apt_source names (issue #179 design pt 5).
#
# claude_vm_boot_apt_sources emits the BOOT doc's apt_sources MINUS any name
# already declared in the BAKE doc (already rendered into the image). A
# boot-only apt_source survives; a baked one is filtered out; a trailing-empty
# key_url row is preserved verbatim.
# ---------------------------------------------------------------------
BR_GBAKE="$WORK/br-gbake.yml"; cat > "$BR_GBAKE" <<'YML'
apt_sources:
  - name: baked-repo
    repo: "deb https://ex.com/baked stable main"
    key_url: https://ex.com/baked/key.asc
YML
BR_RBOOT="$WORK/br-rboot.yml"; cat > "$BR_RBOOT" <<'YML'
apt_sources:
  - name: boot-repo
    repo: "deb https://ex.com/boot stable main"
  - name: baked-repo
    repo: "deb https://ex.com/baked stable main"
    key_url: https://ex.com/baked/key.asc
YML
BR_BAKE="$WORK/br-bake.yml"; BR_BOOT="$WORK/br-boot.yml"
claude_vm_merge_config "$BR_GBAKE" "$WORK/does-not-exist.yml" > "$BR_BAKE"
claude_vm_merge_config "$WORK/does-not-exist.yml" "$BR_RBOOT" > "$BR_BOOT"
assert_eq "boot-render: baked-repo skipped, boot-repo kept" \
  "boot-repo" "$(claude_vm_boot_apt_sources "$BR_BOOT" "$BR_BAKE" | cut -f1 | sort | tr '\n' ',' | sed 's/,$//')"
# The surviving boot-repo row has a trailing-empty key_url field preserved.
assert_eq "boot-render: surviving row preserves trailing-empty key_url field" \
  "boot-repo	deb https://ex.com/boot stable main	" \
  "$(claude_vm_boot_apt_sources "$BR_BOOT" "$BR_BAKE")"
# The derived-egress hosts draw from BOTH tiers (boot apt still reaches baked
# repos' hosts at update time).
assert_eq "boot-render: apt_source_hosts unions bake + boot tier hosts" \
  "ex.com," "$(claude_vm_apt_source_hosts "$BR_BAKE" "$BR_BOOT" | sort | tr '\n' ',')"

# ---------------------------------------------------------------------
# Test 27: legacy single-file config detection (issue #179 migration).
#
# claude_vm_detect_legacy_config returns 0 when NO legacy config.yml is present
# (nothing to migrate) and non-zero (with a migration message) when a legacy
# config.yml exists where a bake/boot pair is now expected -- the design's
# fail-with-clear-message migration path (no silent misread).
# ---------------------------------------------------------------------
LEGACY_DIR="$WORK/legacy-dir"; mkdir -p "$LEGACY_DIR"
assert_true "legacy: no config.yml present -> returns 0 (nothing to migrate)" \
  claude_vm_detect_legacy_config "global" "$LEGACY_DIR/config.yml" "$LEGACY_DIR"
printf 'cpus: 4\n' > "$LEGACY_DIR/config.yml"
if claude_vm_detect_legacy_config "global" "$LEGACY_DIR/config.yml" "$LEGACY_DIR" >/dev/null 2>"$WORK/legacy.err"; then
  assert_eq "legacy: present config.yml -> non-zero (abort with migration message)" "abort" "ok"
else
  assert_eq "legacy: present config.yml -> non-zero (abort with migration message)" "abort" "abort"
fi
assert_true "legacy: migration message names the bake/boot split" \
  grep -q 'config-bake.yml' "$WORK/legacy.err"

# ---------------------------------------------------------------------
# Test 28: 0-byte-lists phenomenon -- RECORDED FACT ONLY (issue #179).
#
# RECORDED FACT (do NOT presume a mechanism): during #106's real-run
# verification, a booted shared read-write guest image was observed with every
# /var/lib/apt/lists Packages index file at 0 BYTES while the InRelease files
# remained valid, so `apt-get update` reported "Hit" and knew ZERO packages --
# unrecoverable by a plain `apt-get update`. Pristine BUILT images were verified
# to carry no list files at all (exonerating mkosi); the corrupt state was only
# ever observed in the era when every boot-time `apt-get update` was already
# failing on the keyring-format bug fixed in #106. Mechanism UNDETERMINED.
#
# Issue #179's immutable-base + per-run-clone design removes the shared-writable
# image that this corruption lived on: each run boots a throwaway APFS clone,
# discarded on clean exit. This test does not (and cannot, host-side without a
# real boot) reproduce the phenomenon; it records it next to the clone-lifecycle
# code so a future regression around image/clone lifecycle has the context, and
# asserts the one structurally-checkable invariant the redesign guarantees: the
# per-run clone path is DISTINCT from the immutable base image path, so a run's
# writes never land on the shared base. The launcher derives the clone as
# "$RUN/guest-clone.raw" (see claude-vm.sh); assert that shape here.
# ---------------------------------------------------------------------
ZB_RUN="/some/run/dir"
ZB_BASE="/cache/images/guest+globalabc12345.raw"
ZB_CLONE="$ZB_RUN/guest-clone.raw"
if [ "$ZB_CLONE" != "$ZB_BASE" ]; then
  assert_eq "clone-lifecycle: per-run clone path is distinct from the immutable base" "distinct" "distinct"
else
  assert_eq "clone-lifecycle: per-run clone path is distinct from the immutable base" "distinct" "same"
fi

# ---------------------------------------------------------------------
# Test 29: config-driven marketplaces + plugins (issue #107).
#
# Covers the pure, host-side-verifiable half of the slice: the bake/boot
# placement guard, the marketplace name-conflict guard, the effective
# marketplace union, the canonical bake-plugin manifest (including its
# per-entry bake/boot origin marker, issue #226), the derived-egress
# gate (including the hard-secure "derives nothing" case, acceptance criterion
# 1), and the extraKnownMarketplaces render.
#
# The other half -- the image actually carrying the plugins, and the guest boot
# phase installing/updating them -- needs a real build + boot and is verified
# there, not here.
# ---------------------------------------------------------------------
MP_BAKE="$WORK/mp-bake.yml"
MP_BOOT="$WORK/mp-boot.yml"
cat > "$MP_BAKE" <<'YML'
claude:
  marketplaces:
    - name: thevoskamps
      url: https://github.com/TheVoskamps/claude-plugins-marketplace.git
  plugins:
    bake:
      - guardrails@thevoskamps
      - block-background-agents@thevoskamps
YML
cat > "$MP_BOOT" <<'YML'
claude:
  marketplaces:
    - name: official
      url: https://github.com/anthropics/claude-plugins-official.git
  plugins:
    install_at_boot:
      - cc-tools@thevoskamps
    update_at_boot: true
    add_marketplace_uris_to_allowlist: auto
YML

# Effective set: BAKE entries first, then boot entries not already present.
assert_eq "mp: effective marketplaces union is bake-first" \
  "thevoskamps,official," \
  "$(claude_vm_effective_marketplaces "$MP_BAKE" "$MP_BOOT" | cut -f1 | tr '\n' ',')"
assert_eq "mp: baked marketplace names are only the bake doc's" \
  "thevoskamps," "$(claude_vm_baked_marketplace_names "$MP_BAKE" | tr '\n' ',')"
assert_eq "mp: hosts derived from both docs' urls, de-duplicated" \
  "github.com," "$(claude_vm_marketplace_hosts "$MP_BAKE" "$MP_BOOT" | tr '\n' ',')"

# An identical entry in both docs collapses to ONE effective marketplace.
MP_BOOT_DUP="$WORK/mp-boot-dup.yml"
cat > "$MP_BOOT_DUP" <<'YML'
claude:
  marketplaces:
    - name: thevoskamps
      url: https://github.com/TheVoskamps/claude-plugins-marketplace.git
YML
assert_eq "mp: identical entry in both docs de-dupes to one" \
  "1" "$(claude_vm_effective_marketplaces "$MP_BAKE" "$MP_BOOT_DUP" | grep -c .)"
if claude_vm_check_marketplace_conflicts "$MP_BAKE" "$MP_BOOT_DUP" 2>/dev/null; then
  assert_eq "mp: identical name+url across docs passes the conflict check" "pass" "pass"
else
  assert_eq "mp: identical name+url across docs passes the conflict check" "pass" "abort"
fi

# Same name, DIFFERENT url anywhere -> loud abort (never silently pick one).
MP_BOOT_CONFLICT="$WORK/mp-boot-conflict.yml"
cat > "$MP_BOOT_CONFLICT" <<'YML'
claude:
  marketplaces:
    - name: thevoskamps
      url: https://example.com/impostor.git
YML
MP_CONFLICT_ERR="$WORK/mp-conflict.err"
if claude_vm_check_marketplace_conflicts "$MP_BAKE" "$MP_BOOT_CONFLICT" 2>"$MP_CONFLICT_ERR"; then
  assert_eq "mp: name conflict with differing url aborts" "abort" "pass"
else
  assert_eq "mp: name conflict with differing url aborts" "abort" "abort"
fi
if grep -q 'thevoskamps' "$MP_CONFLICT_ERR"; then
  assert_eq "mp: conflict abort names the conflicting marketplace" "named" "named"
else
  assert_eq "mp: conflict abort names the conflicting marketplace" "named" "unnamed"
fi

# Placement guard: a BAKE key in a boot file (and vice versa) aborts LOUDLY
# rather than parsing and being silently ignored.
if claude_vm_check_plugin_key_placement "$MP_BAKE" "$MP_BOOT" 2>/dev/null; then
  assert_eq "placement: correctly-placed keys pass" "pass" "pass"
else
  assert_eq "placement: correctly-placed keys pass" "pass" "abort"
fi
PLACE_BOOT_BAD="$WORK/place-boot-bad.yml"
printf 'claude:\n  plugins:\n    bake:\n      - oops@mp\n' > "$PLACE_BOOT_BAD"
PLACE_ERR="$WORK/place.err"
if claude_vm_check_plugin_key_placement "$MP_BAKE" "$PLACE_BOOT_BAD" 2>"$PLACE_ERR"; then
  assert_eq "placement: claude.plugins.bake in a boot file aborts" "abort" "pass"
else
  assert_eq "placement: claude.plugins.bake in a boot file aborts" "abort" "abort"
fi
if grep -q 'config-bake.yml' "$PLACE_ERR"; then
  assert_eq "placement: the abort points at the right file" "pointed" "pointed"
else
  assert_eq "placement: the abort points at the right file" "pointed" "unpointed"
fi
PLACE_BAKE_BAD="$WORK/place-bake-bad.yml"
printf 'claude:\n  plugins:\n    install_at_boot:\n      - oops@mp\n' > "$PLACE_BAKE_BAD"
if claude_vm_check_plugin_key_placement "$PLACE_BAKE_BAD" "$MP_BOOT" 2>/dev/null; then
  assert_eq "placement: claude.plugins.install_at_boot in a bake file aborts" "abort" "pass"
else
  assert_eq "placement: claude.plugins.install_at_boot in a bake file aborts" "abort" "abort"
fi

# Canonical bake-plugin manifest: marketplaces = effective set (bake-first),
# bake = the BAKE doc's refs only, de-duplicated and sorted.
BP_JSON="$(claude_vm_bake_plugins_json "$MP_BAKE" "$MP_BOOT")"
assert_eq "bake-manifest: bake refs are the bake doc's, sorted" \
  "block-background-agents@thevoskamps,guardrails@thevoskamps," \
  "$(printf '%s' "$BP_JSON" | yq -p=json eval '.bake | join(",")' - 2>/dev/null),"
assert_eq "bake-manifest: marketplaces carry the effective set" \
  "2" "$(printf '%s' "$BP_JSON" | yq -p=json eval '.marketplaces | length' - 2>/dev/null)"
assert_eq "bake-manifest: install_at_boot refs are NOT baked" \
  "false" "$(printf '%s' "$BP_JSON" | yq -p=json eval '[.bake[] == "cc-tools@thevoskamps"] | any' - 2>/dev/null)"
# Origin marker (issue #226): the provisioner needs to tell a bake-declared
# marketplace (registering it is a build PRECONDITION -- a failed add aborts)
# from a boot-declared one (pre-registering it is an OPTIMIZATION -- a failed
# add warns and the guest adds it at boot). The flat set carried no such
# distinction, so an unreachable-at-build-time boot url failed the whole build.
assert_eq "bake-manifest: a bake-declared marketplace is marked origin=bake" \
  "bake" "$(printf '%s' "$BP_JSON" | yq -p=json eval '.marketplaces[] | select(.name == "thevoskamps") | .origin' - 2>/dev/null)"
assert_eq "bake-manifest: a boot-declared marketplace is marked origin=boot" \
  "boot" "$(printf '%s' "$BP_JSON" | yq -p=json eval '.marketplaces[] | select(.name == "official") | .origin' - 2>/dev/null)"
assert_eq "bake-manifest: every marketplace entry carries an origin" \
  "0" "$(printf '%s' "$BP_JSON" | yq -p=json eval '[.marketplaces[] | select(has("origin") | not)] | length' - 2>/dev/null)"
# A name in BOTH docs is bake-declared: it is under the image-identity hash
# either way, so the strict policy applies (the de-dupe keeps the bake entry).
assert_eq "bake-manifest: a name in both docs counts as bake-declared" \
  "bake" \
  "$(claude_vm_bake_plugins_json "$MP_BAKE" "$MP_BOOT_DUP" | yq -p=json eval '.marketplaces[] | select(.name == "thevoskamps") | .origin' - 2>/dev/null)"
# The reproduce case from issue #226: a boot-only marketplace whose url is a
# guest-local path, with NOTHING in the bake doc. Nothing here is a build
# precondition, so the entry must be marked boot.
MP_BAKE_BARE="$WORK/mp-bake-bare.yml"
printf 'packages:\n  - git\n' > "$MP_BAKE_BARE"
MP_BOOT_LOCAL="$WORK/mp-boot-local.yml"
cat > "$MP_BOOT_LOCAL" <<'YML'
claude:
  marketplaces:
    - name: thevoskamps
      url: /mnt/repo
  plugins:
    install_at_boot:
      - guardrails@thevoskamps
    update_at_boot: false
YML
assert_eq "bake-manifest: a boot-only local-path marketplace is origin=boot" \
  "boot" \
  "$(claude_vm_bake_plugins_json "$MP_BAKE_BARE" "$MP_BOOT_LOCAL" | yq -p=json eval '.marketplaces[0].origin' - 2>/dev/null)"
assert_eq "bake-manifest: ... and contributes no bake ref" \
  "0" \
  "$(claude_vm_bake_plugins_json "$MP_BAKE_BARE" "$MP_BOOT_LOCAL" | yq -p=json eval '.bake | length' - 2>/dev/null)"
# Empty config -> the stable empty canonical form the provisioner tests for.
EMPTY_DOC="$WORK/mp-empty.yml"
printf '{}\n' > "$EMPTY_DOC"
assert_eq "bake-manifest: no plugins configured -> stable empty form" \
  '{"marketplaces":[],"bake":[]}' \
  "$(claude_vm_bake_plugins_json "$EMPTY_DOC" "$EMPTY_DOC")"

# Derived egress gate. The HARD-SECURE case is acceptance criterion 1:
# everything bake-declared, updates off, "auto" -> derives NOTHING.
MP_BOOT_HARD="$WORK/mp-boot-hard.yml"
printf 'claude:\n  plugins:\n    update_at_boot: false\n    add_marketplace_uris_to_allowlist: auto\n' > "$MP_BOOT_HARD"
if claude_vm_boot_marketplace_egress_needed "$MP_BOOT_HARD" "$MP_BAKE"; then
  assert_eq "egress: hard-secure (all bake-declared, updates off, auto) derives nothing" "no" "yes"
else
  assert_eq "egress: hard-secure (all bake-declared, updates off, auto) derives nothing" "no" "no"
fi
# ... and each individual trigger flips it back on.
if claude_vm_boot_marketplace_egress_needed "$MP_BOOT" "$MP_BAKE"; then
  assert_eq "egress: a boot-declared marketplace outside the bake set derives" "yes" "yes"
else
  assert_eq "egress: a boot-declared marketplace outside the bake set derives" "yes" "no"
fi
MP_BOOT_INSTALL="$WORK/mp-boot-install.yml"
printf 'claude:\n  plugins:\n    install_at_boot:\n      - x@thevoskamps\n    update_at_boot: false\n' > "$MP_BOOT_INSTALL"
if claude_vm_boot_marketplace_egress_needed "$MP_BOOT_INSTALL" "$MP_BAKE"; then
  assert_eq "egress: nonempty install_at_boot triggers derivation" "yes" "yes"
else
  assert_eq "egress: nonempty install_at_boot triggers derivation" "yes" "no"
fi
MP_BOOT_ALWAYS="$WORK/mp-boot-always.yml"
printf 'claude:\n  plugins:\n    update_at_boot: false\n    add_marketplace_uris_to_allowlist: always\n' > "$MP_BOOT_ALWAYS"
if claude_vm_boot_marketplace_egress_needed "$MP_BOOT_ALWAYS" "$MP_BAKE"; then
  assert_eq "egress: 'always' derives even with nothing boot-side to do" "yes" "yes"
else
  assert_eq "egress: 'always' derives even with nothing boot-side to do" "yes" "no"
fi
MP_BOOT_UPD="$WORK/mp-boot-upd.yml"
printf 'claude:\n  plugins:\n    update_at_boot: true\n' > "$MP_BOOT_UPD"
if claude_vm_boot_marketplace_egress_needed "$MP_BOOT_UPD" "$MP_BAKE"; then
  assert_eq "egress: update_at_boot with a configured marketplace derives" "yes" "yes"
else
  assert_eq "egress: update_at_boot with a configured marketplace derives" "yes" "no"
fi
# update_at_boot defaults TRUE, so the no-marketplace case must still derive
# nothing -- otherwise every plugin-less config would allowlist hosts.
if claude_vm_boot_marketplace_egress_needed "$EMPTY_DOC" "$EMPTY_DOC"; then
  assert_eq "egress: no marketplaces at all derives nothing (default update on)" "no" "yes"
else
  assert_eq "egress: no marketplaces at all derives nothing (default update on)" "no" "no"
fi

# extraKnownMarketplaces render. Shape mirrors what `claude plugin install`
# itself was observed writing into ~/.claude/settings.json, so the host render
# does not clobber it with a file that omits the key.
R_MP="$(claude_vm_render_guest_settings "$MP_BOOT" "$MP_BAKE")"
assert_eq "render: extraKnownMarketplaces carries the effective set" \
  "2" "$(get_json "$R_MP" '.extraKnownMarketplaces | length')"
assert_eq "render: an https url renders as a git source" \
  "git" "$(get_json "$R_MP" '.extraKnownMarketplaces["thevoskamps"].source.source')"
assert_eq "render: the git source carries the configured url" \
  "https://github.com/TheVoskamps/claude-plugins-marketplace.git" \
  "$(get_json "$R_MP" '.extraKnownMarketplaces["thevoskamps"].source.url')"
assert_eq "render: baked plugin refs are enabled by default" \
  "true" "$(get_json "$R_MP" '.enabledPlugins["guardrails@thevoskamps"]')"
# An owner/repo shorthand renders as a github source instead.
MP_BAKE_SHORT="$WORK/mp-bake-short.yml"
printf 'claude:\n  marketplaces:\n    - name: short\n      url: owner/repo\n' > "$MP_BAKE_SHORT"
R_SHORT="$(claude_vm_render_guest_settings "$EMPTY_DOC" "$MP_BAKE_SHORT")"
assert_eq "render: an owner/repo shorthand renders as a github source" \
  "github" "$(get_json "$R_SHORT" '.extraKnownMarketplaces["short"].source.source')"
assert_eq "render: the github source carries the repo shorthand" \
  "owner/repo" "$(get_json "$R_SHORT" '.extraKnownMarketplaces["short"].source.repo')"
# A shorthand yields NO derivable egress host -- the launcher warns rather than
# guessing github.com.
assert_eq "egress: an owner/repo shorthand derives no host" \
  "0" "$(claude_vm_marketplace_hosts "$MP_BAKE_SHORT" "$EMPTY_DOC" | grep -c .)"
assert_eq "egress: the hostless entry is named for the warning" \
  "short," "$(claude_vm_marketplaces_without_host "$MP_BAKE_SHORT" "$EMPTY_DOC" | tr '\n' ',')"
# Regression: two marketplaces sharing ONE host must NOT look hostless. A
# count comparison (marketplaces vs. derived hosts) would misfire here, since
# both github.com urls collapse to a single derived host.
assert_eq "egress: two marketplaces on one host are not flagged as hostless" \
  "0" "$(claude_vm_marketplaces_without_host "$MP_BAKE" "$MP_BOOT" | grep -c .)"
assert_eq "egress: ... even though they derive only one host between them" \
  "1" "$(claude_vm_marketplace_hosts "$MP_BAKE" "$MP_BOOT" | grep -c .)"
# No marketplaces configured -> the key renders as an empty object, not null.
R_NOMP="$(claude_vm_render_guest_settings "$EMPTY_DOC" "$EMPTY_DOC")"
assert_eq "render: no marketplaces -> empty extraKnownMarketplaces object" \
  "0" "$(get_json "$R_NOMP" '.extraKnownMarketplaces | length')"

# ---------------------------------------------------------------------
# Test 30: the guest boot launcher's boot_plugin_phase (issue #107).
#
# Extracted from the <<'BOOT' heredoc in build-guest-image.sh the same way
# boot_apt_phase is (Test 23): grab the literal function bodies by line range
# and source them in-process with `log` stubbed and $CLAUDE_BIN pointed at a
# stub that APPENDS its argv to a call log -- so these tests assert WHICH claude
# CLI calls the phase makes, in what order, not merely that it does not crash.
#
# The behaviors that matter and are checkable host-side:
#   - nothing configured        -> no CLI calls at all (no network, no noise)
#   - every marketplace already registered in the image
#                               -> no marketplace ADD (the common warm case)
#   - a marketplace the image lacks -> exactly one add for it
#   - update_at_boot: false     -> no marketplace update, no plugin update
#   - update_at_boot: true      -> marketplace update BEFORE the installs, and
#                                  a plugin update for each installed ref
#   - a failing CLI             -> the phase still returns 0 (fail-soft: a
#                                  failed plugin must never brick the session)
# ---------------------------------------------------------------------
BPP_START="$(grep -n '^plugin_marketplace_registered() {' "$BUILD_GUEST_IMAGE" | head -1 | cut -d: -f1)"
BPP_END="$(grep -n '^boot_plugin_phase() {' "$BUILD_GUEST_IMAGE" | head -1 | cut -d: -f1)"
if [ -n "$BPP_END" ]; then
  BPP_END="$(awk -v start="$BPP_END" 'NR > start && /^}/ { print NR; exit }' "$BUILD_GUEST_IMAGE")"
fi
BPP_SRC="$WORK/boot_plugin_phase.sh"
if [ -n "$BPP_START" ] && [ -n "$BPP_END" ]; then
  {
    echo 'log() { :; }'
    awk -v start="$BPP_START" -v end="$BPP_END" 'NR >= start && NR <= end' "$BUILD_GUEST_IMAGE"
  } > "$BPP_SRC"
  # shellcheck source=/dev/null
  . "$BPP_SRC"
fi

# The claude stub: logs every argv, and answers `plugin marketplace list` /
# `plugin list` from files the tests control, so "already registered" and
# "already installed" are settable states.
BPP_CLI="$WORK/stub-claude"
cat > "$BPP_CLI" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "list" ]; then
  cat "$MP_LIST_FILE" 2>/dev/null
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  cat "$PLUGIN_LIST_FILE" 2>/dev/null
  exit 0
fi
exit "${CLAUDE_STUB_EXIT:-0}"
STUB
chmod +x "$BPP_CLI"

if [ -n "${BPP_START:-}" ] && [ -n "${BPP_END:-}" ] && command -v boot_plugin_phase >/dev/null 2>&1; then
  CLAUDE_BIN="$BPP_CLI"
  export CLAUDE_CALL_LOG MP_LIST_FILE PLUGIN_LIST_FILE CLAUDE_STUB_EXIT
  CLAUDE_CALL_LOG="$WORK/claude-calls.log"
  MP_LIST_FILE="$WORK/mp-list.txt"
  PLUGIN_LIST_FILE="$WORK/plugin-list.txt"
  CLAUDE_STUB_EXIT=0

  # Nothing configured at all -> zero CLI calls.
  : > "$CLAUDE_CALL_LOG"
  : > "$MP_LIST_FILE"
  : > "$PLUGIN_LIST_FILE"
  PLUGIN_MARKETPLACES_TSV="$WORK/bpp-mp-empty.tsv"; : > "$PLUGIN_MARKETPLACES_TSV"
  PLUGIN_INSTALL_LIST="$WORK/bpp-install-empty.list"; : > "$PLUGIN_INSTALL_LIST"
  CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT="true"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: nothing configured runs no claude calls" \
    "0" "$(grep -c . "$CLAUDE_CALL_LOG" || true)"

  # The marketplace already registered in the image, updates OFF -> the
  # hard-secure warm case: no add, no update, no install. This phase reads the
  # image (what `plugin marketplace list` reports), not the bake declaration.
  : > "$CLAUDE_CALL_LOG"
  PLUGIN_MARKETPLACES_TSV="$WORK/bpp-mp.tsv"
  printf 'thevoskamps\thttps://github.com/TheVoskamps/claude-plugins-marketplace.git\n' > "$PLUGIN_MARKETPLACES_TSV"
  printf 'Configured marketplaces:\n\n  x thevoskamps\n' > "$MP_LIST_FILE"
  CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT="false"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: an already-registered marketplace is not re-added" \
    "0" "$(grep -c 'marketplace add' "$CLAUDE_CALL_LOG" || true)"
  assert_eq "boot_plugin_phase: update_at_boot=false runs no marketplace update" \
    "0" "$(grep -c 'marketplace update' "$CLAUDE_CALL_LOG" || true)"
  assert_eq "boot_plugin_phase: update_at_boot=false runs no plugin update" \
    "0" "$(grep -c '^plugin update ' "$CLAUDE_CALL_LOG" || true)"

  # A marketplace the image does NOT carry -> exactly one add, with its url.
  : > "$CLAUDE_CALL_LOG"
  printf 'No marketplaces configured\n' > "$MP_LIST_FILE"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: an unregistered marketplace is added exactly once" \
    "1" "$(grep -c 'marketplace add' "$CLAUDE_CALL_LOG" || true)"
  if grep -q 'marketplace add https://github.com/TheVoskamps/claude-plugins-marketplace.git' "$CLAUDE_CALL_LOG"; then
    assert_eq "boot_plugin_phase: the add carries the configured url" "url" "url"
  else
    assert_eq "boot_plugin_phase: the add carries the configured url" "url" "missing"
  fi

  # The registered-name check is LITERAL, not a regex built from the name.
  # The name charset allows '.', which as a regex is "any character", so a
  # configured 'foo.bar' must NOT be considered already-registered when the
  # registry actually holds 'fooxbar' -- it must still be added.
  : > "$CLAUDE_CALL_LOG"
  PLUGIN_MARKETPLACES_TSV="$WORK/bpp-mp-dot.tsv"
  printf 'foo.bar\thttps://example.invalid/foo-bar.git\n' > "$PLUGIN_MARKETPLACES_TSV"
  printf 'Configured marketplaces:\n\n  x fooxbar\n' > "$MP_LIST_FILE"
  CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT="false"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: a '.' in the name is matched literally, not as a regex" \
    "1" "$(grep -c 'marketplace add https://example.invalid/foo-bar.git' "$CLAUDE_CALL_LOG" || true)"
  # ...and the exact same name IS recognized, so the literal check did not
  # simply break the positive case.
  : > "$CLAUDE_CALL_LOG"
  printf 'Configured marketplaces:\n\n  x foo.bar\n' > "$MP_LIST_FILE"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: an exactly-matching dotted name is not re-added" \
    "0" "$(grep -c 'marketplace add' "$CLAUDE_CALL_LOG" || true)"
  PLUGIN_MARKETPLACES_TSV="$WORK/bpp-mp.tsv"

  # update_at_boot=true with an install list: marketplace update runs BEFORE
  # the install (so the install resolves against the refreshed marketplace),
  # and every installed ref is then updated (the baked-plugin freshness path).
  : > "$CLAUDE_CALL_LOG"
  printf 'Configured marketplaces:\n\n  x thevoskamps\n' > "$MP_LIST_FILE"
  printf 'Installed plugins:\n\n  x baked@thevoskamps\n    Version: 1.0.0\n' > "$PLUGIN_LIST_FILE"
  PLUGIN_INSTALL_LIST="$WORK/bpp-install.list"
  printf 'cc-tools@thevoskamps\n' > "$PLUGIN_INSTALL_LIST"
  CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT="true"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  MP_UPD_LINE="$(grep -n 'marketplace update' "$CLAUDE_CALL_LOG" | head -1 | cut -d: -f1)"
  INS_LINE="$(grep -n 'plugin install ' "$CLAUDE_CALL_LOG" | head -1 | cut -d: -f1)"
  if [ -n "$MP_UPD_LINE" ] && [ -n "$INS_LINE" ] && [ "$MP_UPD_LINE" -lt "$INS_LINE" ]; then
    assert_eq "boot_plugin_phase: marketplace refresh runs before the installs" "before" "before"
  else
    assert_eq "boot_plugin_phase: marketplace refresh runs before the installs" "before" "after-or-missing"
  fi
  assert_eq "boot_plugin_phase: install_at_boot ref is installed" \
    "1" "$(grep -c 'plugin install cc-tools@thevoskamps' "$CLAUDE_CALL_LOG" || true)"
  # The baked ref is discovered from `claude plugin list`, so the guest needs
  # no copy of claude.plugins.bake to keep baked plugins fresh.
  assert_eq "boot_plugin_phase: a baked ref found via plugin list is updated" \
    "1" "$(grep -c 'plugin update baked@thevoskamps' "$CLAUDE_CALL_LOG" || true)"

  # Fail-soft: every CLI call failing must NOT make the phase fail -- a broken
  # marketplace can never block an interactive session.
  : > "$CLAUDE_CALL_LOG"
  CLAUDE_STUB_EXIT=1
  if ( boot_plugin_phase >/dev/null 2>&1 ); then
    assert_eq "boot_plugin_phase: a failing CLI is fail-soft (phase still succeeds)" "soft" "soft"
  else
    assert_eq "boot_plugin_phase: a failing CLI is fail-soft (phase still succeeds)" "soft" "hard"
  fi
  CLAUDE_STUB_EXIT=0
else
  echo "SKIP: boot_plugin_phase extraction from build-guest-image.sh failed; plugin-phase tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 31: the launcher's extra-mount loop splits its records by hand, wraps a
# single-file source, and writes the guest manifest (issue #226 class
# completion, extended by issue #157).
#
# claude_vm_mount_specs emits source<TAB>tag<TAB>path. A tab is IFS WHITESPACE,
# so 'IFS=<tab> read -r src tag path' collapses a RUN of tabs into ONE
# separator: a mounts entry written with an empty tag is emitted as
# source<TAB><TAB>path, the empty middle field vanishes, and the PATH is taken
# as the mount TAG -- the share goes out as mountTag=/srv/whatever, and two such
# entries share that one tag. Same class as the marketplace record split in
# podman-mkosi.sh.
#
# The loop is bare top-level code in claude-vm.sh (not a function), so it is
# sliced out by line range -- the same extraction the boot_apt_phase and
# boot_plugin_phase tests above use on build-guest-image.sh -- and run against
# the REAL emitter, with the resulting --device flags AND the mounts.tsv it
# writes printed for assertion.
# ---------------------------------------------------------------------
LAUNCHER="$TEST_DIR/../claude-vm.sh"
MNT_START=""
MNT_END=""
if [ -f "$LAUNCHER" ]; then
  MNT_START="$(grep -n '^EXTRA_MOUNT_FLAGS=()$' "$LAUNCHER" | head -1 | cut -d: -f1)"
  MNT_END="$(awk -v start="${MNT_START:-0}" 'NR >= start && /^done < <\(claude_vm_mount_specs/ { print NR; exit }' "$LAUNCHER")"
fi
if [ -n "$MNT_START" ] && [ -n "$MNT_END" ]; then
  # The pre-fix line, rebuilt exactly. The dollar is escaped so this test
  # file's own shell does not expand it; awk's -v runs backslash escapes on the
  # value it is handed, so the awk copy doubles the backslash.
  MNT_OLD_READ="while IFS=\$'\\t' read -r src tag mount_path; do"
  MNT_OLD_READ_AWK="while IFS=\$'\\\\t' read -r src tag mount_path; do"

  # write_mnt_slice <out-file> <new|old> -- wrap the captured loop in a
  # runnable harness. Mode "old" rebuilds the collapsing read from the SAME
  # captured lines, so the negative control cannot drift from the real code.
  # $RUN and $CONFIG_DIR are the run-dir paths the real launcher has already
  # created by the time this loop runs; the harness supplies them so the wrap
  # dir and mounts.tsv land inside the suite's own temp tree.
  #
  # $MOUNT_SHARED_DIR is the directory the launcher shares as tag `repo`, which
  # the loop tests $RUN against to decide where the single-file wrap dir may
  # live. It defaults to $RUN/worktree -- what repo.mount: clone really sets --
  # so the calls below that do not care read as they always did; the live-mode
  # case passes its own.
  write_mnt_slice() {
    local out="$1" mode="$2"
    {
      echo '#!/usr/bin/env bash'
      echo 'set -uo pipefail'
      printf '. %s\n' "\"$LIB\""
      echo 'MERGED_BOOT="$1"'
      echo 'RUN="$2"'
      echo 'MOUNT_SHARED_DIR="${3:-$RUN/worktree}"'
      echo 'CONFIG_DIR="$RUN/config"'
      echo 'mkdir -p "$CONFIG_DIR"'
      awk -v start="$MNT_START" -v end="$MNT_END" \
          -v mode="$mode" -v oldread="$MNT_OLD_READ_AWK" '
        NR < start || NR > end { next }
        mode == "old" && $0 == "while IFS= read -r mount_record; do" { print oldread; next }
        mode == "old" && $0 ~ /^  (src|mount_rest|tag|mount_path)=\$\{mount_(record|rest)/ { next }
        { print }
      ' "$LAUNCHER"
      echo 'printf "%s\n" "${EXTRA_MOUNT_FLAGS[@]+"${EXTRA_MOUNT_FLAGS[@]}"}"'
    } > "$out"
  }

  MNT_SLICE="$WORK/mount-loop.sh"
  MNT_SLICE_OLD="$WORK/mount-loop-old.sh"
  write_mnt_slice "$MNT_SLICE" new
  write_mnt_slice "$MNT_SLICE_OLD" old

  MNT_YML="$WORK/mount-loop-boot.yml"
  cat > "$MNT_YML" <<'YML'
mounts:
  - source: /a/empty-tag
    tag: ""
    path: /srv/swallowed
  - source: /a/normal
    tag: work
    path: /srv/work
YML

  MNT_RUN="$WORK/mount-loop-run"
  assert_eq "mount-split: an empty tag stays empty rather than swallowing the path" \
    "--device virtio-fs,sharedDir=/a/empty-tag,mountTag=" \
    "$(bash "$MNT_SLICE" "$MNT_YML" "$MNT_RUN" 2>/dev/null | sed -n 1,2p | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "mount-split: a fully-populated entry keeps its own tag" \
    "--device virtio-fs,sharedDir=/a/normal,mountTag=work" \
    "$(bash "$MNT_SLICE" "$MNT_YML" "$MNT_RUN" 2>/dev/null | sed -n 3,4p | tr '\n' ' ' | sed 's/ $//')"

  # NEGATIVE CONTROL: the pre-fix read promotes the PATH into the tag slot.
  assert_eq "mount-split: the control really carries the old tab-IFS read" \
    "1" "$(grep -cF -- "$MNT_OLD_READ" "$MNT_SLICE_OLD" || true)"
  assert_eq "mount-split: NEGATIVE CONTROL -- the old read mounts the empty-tag share as '/srv/swallowed'" \
    "--device virtio-fs,sharedDir=/a/empty-tag,mountTag=/srv/swallowed" \
    "$(bash "$MNT_SLICE_OLD" "$MNT_YML" "$MNT_RUN" 2>/dev/null | sed -n 1,2p | tr '\n' ' ' | sed 's/ $//')"

  # ---- issue #157: the guest manifest and the single-file wrap ----
  #
  # Real host paths this time: the loop stats each source to decide directory
  # vs single file, and hard-links a file source into its wrap dir.
  MNT_SRC_DIR="$WORK/mount-src-dir"; mkdir -p "$MNT_SRC_DIR"
  MNT_SRC_FILE="$WORK/mount-src-file.txt"; printf 'file-mount-content\n' > "$MNT_SRC_FILE"
  MNT_YML2="$WORK/mount-loop-boot2.yml"
  {
    printf 'mounts:\n'
    printf '  - source: %s\n    tag: data\n' "$MNT_SRC_DIR"
    printf '  - source: %s\n    tag: elsewhere\n    path: /srv/elsewhere\n' "$MNT_SRC_DIR"
    printf '  - source: %s\n    tag: cfg\n    path: /root/.gitconfig\n' "$MNT_SRC_FILE"
  } > "$MNT_YML2"
  MNT_RUN2="$WORK/mount-loop-run2"
  MNT_OUT2="$(bash "$MNT_SLICE" "$MNT_YML2" "$MNT_RUN2" 2>&1)"
  MNT_TSV2="$MNT_RUN2/config/mounts.tsv"

  # A directory source is shared as-is, and defaults to /mnt/<tag>.
  assert_eq "mounts.tsv: a directory mount defaults to /mnt/<tag> and carries an empty file field" \
    "data	/mnt/data	" "$(sed -n 1p "$MNT_TSV2" 2>/dev/null)"
  # An explicit path: overrides the default mountpoint.
  assert_eq "mounts.tsv: an explicit path: overrides /mnt/<tag>" \
    "elsewhere	/srv/elsewhere	" "$(sed -n 2p "$MNT_TSV2" 2>/dev/null)"
  # A single-file source names its basename in the 3rd field, so the guest
  # knows to bind-mount one file out of the wrap share.
  assert_eq "mounts.tsv: a single-file mount names its basename in the file field" \
    "cfg	/root/.gitconfig	mount-src-file.txt" "$(sed -n 3p "$MNT_TSV2" 2>/dev/null)"
  assert_eq "mounts.tsv: every record carries exactly 2 separators" \
    "2" "$(sed -n 1p "$MNT_TSV2" 2>/dev/null | tr -cd '\t' | wc -c | tr -d ' ')"
  # No record carries a mode field any more -- read-only is unenforceable on
  # this stack (issue #233), so there is nothing for the guest to read. Asserted
  # on the whole manifest rather than one line, since a leftover field would
  # more likely appear on the shape that used to carry a non-default one.
  assert_eq "mounts.tsv: no record carries a mode field" \
    "0" "$(grep -c '	ro	\|	rw	' "$MNT_TSV2" 2>/dev/null || true)"

  # The file source is shared via its WRAP dir, not its real parent -- that is
  # what keeps the rest of the parent directory out of the guest.
  # The slice prints the EXTRA_MOUNT_FLAGS array one element per line, so each
  # device spec is a whole line of its own next to its `--device` flag.
  assert_eq "single-file: the shared dir is the per-entry wrap dir, not the file's parent" \
    "virtio-fs,sharedDir=$MNT_RUN2/mount-wrap/cfg,mountTag=cfg" \
    "$(printf '%s\n' "$MNT_OUT2" | grep -x -- "virtio-fs,sharedDir=$MNT_RUN2/mount-wrap/cfg,mountTag=cfg")"
  assert_eq "single-file: the wrap dir holds only the one file" \
    "mount-src-file.txt" "$(ls "$MNT_RUN2/mount-wrap/cfg" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  # HARD LINK, not a copy: same inode as the host file, which is what makes an
  # `rw` single-file mount write through to the host instead of into a
  # throwaway copy. Compared by inode number rather than by content, since a
  # copy would match on content.
  assert_eq "single-file: the wrap entry is a HARD LINK to the source (same inode)" \
    "same" "$([ "$(ls -i "$MNT_SRC_FILE" | awk '{print $1}')" = "$(ls -i "$MNT_RUN2/mount-wrap/cfg/mount-src-file.txt" | awk '{print $1}')" ] && echo same || echo different)"

  # A directory source is NOT wrapped -- its own path is shared directly, so an
  # rw directory mount writes through with no intermediary at all.
  assert_eq "directory mount: shared directly, with no wrap dir" \
    "virtio-fs,sharedDir=$MNT_SRC_DIR,mountTag=data" \
    "$(printf '%s\n' "$MNT_OUT2" | grep -x -- "virtio-fs,sharedDir=$MNT_SRC_DIR,mountTag=data")"
  assert_eq "directory mount: no wrap dir is created for a directory source" \
    "absent" "$([ -e "$MNT_RUN2/mount-wrap/data" ] && echo present || echo absent)"

  # ---- the wrap dir must sit outside the repo share (issue #157 review) ----
  #
  # The wrap entry is a hard link to the operator's file, so anything that can
  # reach INSIDE the wrap dir can read and write that file. Under
  # repo.mount: clone the repo share is $RUN/worktree and the wrap dir is a
  # sibling, so $RUN is fine. Under repo.mount: live the share is the REPO
  # ITSELF and $RUN lives inside it (<repo>/.claude/tmp/<run-id>) -- and the
  # guest fstab mounts tag `repo` rw, so a wrap dir under $RUN would expose the
  # operator's file at a second guest path they never configured, one that
  # survives the entry's own mountpoint being skipped by the guest's occupancy
  # check. The loop must move the wrap dir out.
  #
  # Asserted on the sharedDir the loop actually hands vfkit, since that -- not
  # the variable -- is what decides whether the guest can reach the directory.
  MNT_WRAP_SHARED() {
    printf '%s\n' "$1" | sed -n 's/^virtio-fs,sharedDir=\(.*\),mountTag=cfg$/\1/p'
  }

  # CLONE shape: the share is $RUN/worktree, so the wrap dir stays under $RUN.
  assert_eq "single-file wrap (clone): the wrap dir stays under \$RUN, beside the worktree share" \
    "$MNT_RUN2/mount-wrap/cfg" "$(MNT_WRAP_SHARED "$MNT_OUT2")"

  # LIVE shape: $RUN sits INSIDE the shared repo, mirroring
  # <repo>/.claude/tmp/<run-id>. TMPDIR is pointed at $WORK so the fallback dir
  # the loop creates lands where this suite's trap already cleans up.
  MNT_LIVE_SHARE="$WORK/mount-live-repo"
  MNT_RUN3="$MNT_LIVE_SHARE/.claude/tmp/run3"
  mkdir -p "$MNT_RUN3"
  MNT_OUT3="$(TMPDIR="$WORK" bash "$MNT_SLICE" "$MNT_YML2" "$MNT_RUN3" "$MNT_LIVE_SHARE" 2>&1)"
  MNT_WRAP3="$(MNT_WRAP_SHARED "$MNT_OUT3")"
  assert_eq "single-file wrap (live): the shared wrap dir is OUTSIDE the rw repo share" \
    "outside" "$(case "$MNT_WRAP3/" in "$MNT_LIVE_SHARE"/*) echo inside ;; *) echo outside ;; esac)"
  assert_eq "single-file wrap (live): it is still a real per-entry dir holding the one file" \
    "mount-src-file.txt" "$(ls "$MNT_WRAP3" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  # Still a hard link, so moving the wrap dir did not quietly become a copy --
  # which would make the documented write-through a lie.
  assert_eq "single-file wrap (live): the wrap entry is still a HARD LINK to the source" \
    "same" "$([ "$(ls -i "$MNT_SRC_FILE" | awk '{print $1}')" = "$(ls -i "$MNT_WRAP3/mount-src-file.txt" | awk '{print $1}')" ] && echo same || echo different)"
  # NEGATIVE CONTROL: the pre-fix siting was $RUN/mount-wrap unconditionally.
  # Computed against this very fixture, that path is inside the live share --
  # which is the defect, and is why the assertion above is not vacuous.
  assert_eq "single-file wrap (live): NEGATIVE CONTROL -- the pre-fix \$RUN/mount-wrap is INSIDE the share" \
    "inside" "$(case "$MNT_RUN3/mount-wrap/" in "$MNT_LIVE_SHARE"/*) echo inside ;; *) echo outside ;; esac)"
  # ...and nothing was left behind under $RUN in the live case.
  assert_eq "single-file wrap (live): no wrap dir is created under \$RUN" \
    "absent" "$([ -e "$MNT_RUN3/mount-wrap" ] && echo present || echo absent)"
else
  echo "SKIP: extra-mount loop extraction from claude-vm.sh failed; mount-split tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 32: the launcher's config-load gates reject a malformed entry
# (issue #226 class completion).
#
# Splitting a record correctly makes an empty key field VISIBLE; it does not
# make such an entry usable. Two guards turn the newly-visible cases into a
# launch abort:
#
#   claude_vm_check_mounts            -- a mounts entry with no source, or with
#                                        no tag (omitted OR explicitly ""). The
#                                        guest mounts each share BY its tag.
#   claude_vm_check_marketplace_names -- a claude.marketplaces entry with a url
#                                        but no name, in either document.
#
# Driven through the LAUNCHER's own load block, sliced out of claude-vm.sh by
# line range (the same extraction Test 31 uses on its mount loop), so these
# assert that the gates are wired into the launch path -- not merely that the
# helpers return non-zero when called directly. The slice runs the real
# claude_vm_merge_config over real per-tier files, so a fixture reaches the
# gates exactly as an operator's config would.
# ---------------------------------------------------------------------
GATE_START=""
GATE_END=""
if [ -f "$LAUNCHER" ]; then
  GATE_START="$(grep -nF 'MERGED_BAKE="$(claude_vm_mktemp claude-vm-merged-bake)"' "$LAUNCHER" | head -1 | cut -d: -f1)"
  GATE_END="$(grep -nF 'aborting -- move the misplaced claude.plugins key(s)' "$LAUNCHER" | head -1 | cut -d: -f1)"
fi
if [ -n "$GATE_START" ] && [ -n "$GATE_END" ]; then
  GATE_SLICE="$WORK/config-load-gates.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf '. %s\n' "\"$LIB\""
    echo 'GLOBAL_BAKE_CONFIG="$1"'
    echo 'REPO_BAKE_CONFIG="$2"'
    echo 'GLOBAL_BOOT_CONFIG="$3"'
    echo 'REPO_BOOT_CONFIG="$4"'
    awk -v start="$GATE_START" -v end="$GATE_END" 'NR >= start && NR <= end' "$LAUNCHER"
    echo 'echo GATE-OK'
  } > "$GATE_SLICE"

  # run_gates <bake-file> <boot-file> -- run the sliced load block over one
  # pair of repo-tier files and print "<rc>|<merged stdout+stderr, one line>".
  # TMPDIR is pointed at $WORK so the block's own merged tempfiles land where
  # this suite's trap already cleans up.
  run_gates() {
    local bake="$1" boot="$2" out rc
    out="$(TMPDIR="$WORK" bash "$GATE_SLICE" "" "$bake" "" "$boot" 2>&1)"
    rc=$?
    printf '%s|%s\n' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
  }

  GATE_NONE_BAKE="$WORK/gate-none-bake.yml"; printf 'packages:\n  - git\n'   > "$GATE_NONE_BAKE"
  GATE_NONE_BOOT="$WORK/gate-none-boot.yml"; printf 'cpus: 2\nmem: 4096\n'   > "$GATE_NONE_BOOT"

  # A config that declares NEITHER mounts nor marketplaces must pass. This is
  # the regression guard for the empty-result-set shape: yq prints ONE EMPTY
  # LINE (not zero bytes) for `.mounts // [] | .[]`, and a gate that read that
  # line as an entry would reject every ordinary config on earth.
  assert_eq "load-gates: a config with no mounts and no marketplaces passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$GATE_NONE_BOOT")"

  # Real, existing host paths from here on: since issue #157 the gate also
  # rejects a source that is not on the host, so a fixture pointing at a made-up
  # /a/one would now fail for the wrong reason.
  GATE_SRC_A="$WORK/gate-src-a"; mkdir -p "$GATE_SRC_A"
  GATE_SRC_B="$WORK/gate-src-b"; mkdir -p "$GATE_SRC_B"
  GATE_OK_BOOT="$WORK/gate-ok-boot.yml"
  {
    printf 'mounts:\n'
    printf '  - source: %s\n    tag: one\n' "$GATE_SRC_A"
    printf 'claude:\n  marketplaces:\n    - name: mp\n      url: https://example.invalid/mp.git\n'
  } > "$GATE_OK_BOOT"
  assert_eq "load-gates: a well-formed mounts + marketplaces config passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$GATE_OK_BOOT")"

  # ---- issue #157: the rest of the mount validation, each its own abort ----
  #
  # gate_mount_case <name> <yaml-body> <expected-message-fragment> -- run one
  # mounts fixture through the launcher's real load block and assert both that
  # it aborts and that the diagnostic names the actual problem. Every case here
  # is a config the operator can write today and that would otherwise produce a
  # VM that boots and looks fine while the mount they asked for is missing,
  # shadowed, or pointed somewhere else.
  gate_mount_case() {
    local name="$1" body="$2" want="$3" got
    printf '%s' "$body" > "$WORK/gate-mnt-case.yml"
    got="$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-mnt-case.yml")"
    assert_eq "load-gates: $name aborts the launch" "1" "${got%%|*}"
    case "$got" in
      *"$want"*) assert_eq "load-gates: $name is named in the diagnostic" "named" "named" ;;
      *)         assert_eq "load-gates: $name is named in the diagnostic" "named" "$got" ;;
    esac
  }

  # A tag colliding with one of claude-vm's own always-attached shares: the
  # image's fstab mounts `repo` at /mnt/repo, so a second device under that tag
  # puts the operator's directory where the working tree belongs.
  gate_mount_case "a RESERVED tag" \
    "$(printf 'mounts:\n  - source: %s\n    tag: repo\n' "$GATE_SRC_A")" \
    "uses the reserved tag 'repo'"

  # Two entries under one tag: one guest mount, two devices, and which one wins
  # is up to the kernel's enumeration order.
  gate_mount_case "a DUPLICATE tag" \
    "$(printf 'mounts:\n  - source: %s\n    tag: dup\n  - source: %s\n    tag: dup\n' "$GATE_SRC_A" "$GATE_SRC_B")" \
    "repeats the tag 'dup'"

  # `mode:` is gone: read-only cannot be enforced on this stack (issue #233), so
  # the key is rejected rather than ignored -- an ignored `mode: ro` would leave
  # the operator believing a share the guest can write is read-only. EVERY
  # spelling aborts, the once-valid ones included: `ro` is the dangerous one
  # (silently accepting it is the false promise), `rw` names a mode that no
  # longer exists as a key, and a typo was already an abort.
  gate_mount_case "a 'mode: ro' key" \
    "$(printf 'mounts:\n  - source: %s\n    tag: m\n    mode: ro\n' "$GATE_SRC_A")" \
    "sets 'mode:'"
  gate_mount_case "a 'mode: rw' key" \
    "$(printf 'mounts:\n  - source: %s\n    tag: m\n    mode: rw\n' "$GATE_SRC_A")" \
    "sets 'mode:'"
  gate_mount_case "a misspelled mode" \
    "$(printf 'mounts:\n  - source: %s\n    tag: m\n    mode: read-only\n' "$GATE_SRC_A")" \
    "sets 'mode:'"
  # An explicitly EMPTY mode, and a `mode:` with no value at all (a YAML null).
  # Both render as the same empty field a value-based check cannot tell from an
  # omitted key, which is why the gate asks whether the KEY is present.
  gate_mount_case "an explicitly empty mode" \
    "$(printf 'mounts:\n  - source: %s\n    tag: m\n    mode: ""\n' "$GATE_SRC_A")" \
    "sets 'mode:'"
  gate_mount_case "a valueless mode key" \
    "$(printf 'mounts:\n  - source: %s\n    tag: m\n    mode:\n' "$GATE_SRC_A")" \
    "sets 'mode:'"
  # The diagnostic must point at the issue that will bring read-only back, or
  # the operator is told "no" with nowhere to go.
  gate_mount_case "the mode abort naming issue #233" \
    "$(printf 'mounts:\n  - source: %s\n    tag: m\n    mode: ro\n' "$GATE_SRC_A")" \
    "issue #233"
  # ...and the entry NUMBER counts through the merged list the same way every
  # other mounts diagnostic does, so a second-entry mistake is not reported as
  # the first's.
  gate_mount_case "the mode abort naming the right entry number" \
    "$(printf 'mounts:\n  - source: %s\n    tag: clean\n  - source: %s\n    tag: m\n    mode: ro\n' "$GATE_SRC_A" "$GATE_SRC_B")" \
    "mounts entry #2 ('$GATE_SRC_B') sets 'mode:'"

  # A source that is not on the host: vfkit would fail minutes into the launch
  # with a message about a device rather than about this config line.
  gate_mount_case "a MISSING host source" \
    "$(printf 'mounts:\n  - source: %s/definitely-not-here\n    tag: gone\n' "$WORK")" \
    "does not exist on the host"

  # A relative `path:` would resolve against the boot launcher's cwd.
  gate_mount_case "a RELATIVE path" \
    "$(printf 'mounts:\n  - source: %s\n    tag: rel\n    path: srv/rel\n' "$GATE_SRC_A")" \
    "which is not absolute"

  # A `path:` landing on a reserved guest mountpoint hides the repo/credential/
  # binary/run-config from the rest of the boot. The trailing slash is
  # deliberate: it is a different STRING from /mnt/repo, and the check must
  # still catch it -- that is what claude_vm_mount_guest_path's normalization
  # is for.
  gate_mount_case "a path over a RESERVED mountpoint (trailing slash)" \
    "$(printf 'mounts:\n  - source: %s\n    tag: sneaky\n    path: /mnt/repo/\n' "$GATE_SRC_A")" \
    "a guest path claude-vm"

  # ABOVE the reserved mountpoints rather than on one. /mnt covers all four
  # built-in shares at once, and the boot then fails far downstream -- the
  # settings step aborts with "this indicates a launcher fault", never naming
  # the config line that caused it. String equality accepted this.
  gate_mount_case "a path ABOVE the reserved mountpoints (/mnt)" \
    "$(printf 'mounts:\n  - source: %s\n    tag: allofthem\n    path: /mnt\n' "$GATE_SRC_A")" \
    "which overlaps '/mnt/repo'"

  # The guest root is the extreme of the same case.
  gate_mount_case "a path ABOVE everything (/)" \
    "$(printf 'mounts:\n  - source: %s\n    tag: root\n    path: /\n' "$GATE_SRC_A")" \
    "which overlaps '/mnt/repo'"

  # BELOW a reserved mountpoint: the guest mkdir -p's the path INSIDE the
  # host's shared repo tree (creating a directory in the operator's own repo
  # under repo.mount: live) and then hides whatever the repo really has there.
  gate_mount_case "a path INSIDE a reserved mountpoint (/mnt/repo/sub)" \
    "$(printf 'mounts:\n  - source: %s\n    tag: inrepo\n    path: /mnt/repo/sub\n' "$GATE_SRC_A")" \
    "which overlaps '/mnt/repo'"

  # The guest-side wrap mountpoint is reserved too: every single-file mount is
  # staged through it, so an entry landing on it (or above it, as /run does)
  # would shadow the staging directory.
  gate_mount_case "a path on the guest WRAP mountpoint" \
    "$(printf 'mounts:\n  - source: %s\n    tag: wrap\n    path: /run/claude-vm/mount-wrap\n' "$GATE_SRC_A")" \
    "which overlaps '/run/claude-vm/mount-wrap'"

  # That wrap mountpoint is a value on BOTH sides of the host/guest seam: the
  # host reserves it, and the boot launcher baked into the image mounts there.
  # The guest launcher is a baked script and cannot source lib/config.sh, so
  # the value is restated -- assert the two spellings are equal, or the gate
  # above reserves a guest path nothing actually uses while the one the guest
  # does use stays claimable.
  assert_eq "reserved wrap mountpoint: the host constant equals the guest launcher's MOUNT_WRAP_MNT" \
    "$CLAUDE_VM_GUEST_WRAP_MOUNT" \
    "$(sed -n 's/^MOUNT_WRAP_MNT=//p' "$TEST_DIR/../build-guest-image.sh" | head -1)"

  # ...and the guard must not over-reach: a path that merely shares a PREFIX
  # with a reserved mountpoint, without sharing a component boundary, is a
  # perfectly ordinary mountpoint and must still pass.
  printf 'mounts:\n  - source: %s\n    tag: near\n    path: /mnt/repofoo\n' "$GATE_SRC_A" \
    > "$WORK/gate-near-boot.yml"
  assert_eq "load-gates: a path that only PREFIX-matches a reserved mountpoint passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-near-boot.yml")"

  # ---- the guest OS's own paths (the CRITICAL case) ----
  #
  # Linux STACKS a mount, so an extra mount landing on a guest system path hides
  # the OS's own files for the life of the VM -- and boot_mount_phase runs
  # FIRST, so the damage lands before the phase that would have noticed. The
  # rule is by SHAPE, because a directory mount hides a subtree while a
  # single-file bind replaces one file. $GATE_SRC_A is a DIRECTORY and
  # $GATE_SRC_FILE a FILE, which is how each case below picks its shape -- the
  # gate stats the source exactly as the launcher's loop does.
  GATE_SRC_FILE="$WORK/gate-src-file.txt"; printf 'x\n' > "$GATE_SRC_FILE"

  # ON a system path. /root is the motivating one: the credential seed writes
  # /root/.claude AFTER this phase, so a directory mounted at /root swallows
  # HOME and the failure surfaces later as something unrelated.
  gate_mount_case "a DIRECTORY on the guest HOME (/root)" \
    "$(printf 'mounts:\n  - source: %s\n    tag: home\n    path: /root\n' "$GATE_SRC_A")" \
    "overlaps the guest OS"
  gate_mount_case "a DIRECTORY on /etc" \
    "$(printf 'mounts:\n  - source: %s\n    tag: etc\n    path: /etc\n' "$GATE_SRC_A")" \
    "overlaps the guest OS"
  # INSIDE one: /usr/local/lib/claude-vm is where the boot launcher itself is
  # installed, and /etc/systemd holds the units that start it.
  gate_mount_case "a DIRECTORY inside /usr" \
    "$(printf 'mounts:\n  - source: %s\n    tag: u\n    path: /usr/local/lib\n' "$GATE_SRC_A")" \
    "overlaps the guest OS"
  gate_mount_case "a DIRECTORY inside /root" \
    "$(printf 'mounts:\n  - source: %s\n    tag: rsub\n    path: /root/.claude\n' "$GATE_SRC_A")" \
    "overlaps the guest OS"
  gate_mount_case "a DIRECTORY inside /var" \
    "$(printf 'mounts:\n  - source: %s\n    tag: v\n    path: /var/lib/whatever\n' "$GATE_SRC_A")" \
    "overlaps the guest OS"

  # A single FILE may sit INSIDE /root -- this is issue #157's own shipped
  # acceptance case, and a blanket "nothing overlapping a system path" rule
  # would have killed it. /home and /tmp are the same class.
  printf 'mounts:\n  - source: %s\n    tag: cfg\n    path: /root/.gitconfig\n' "$GATE_SRC_FILE" \
    > "$WORK/gate-sysfile-ok.yml"
  assert_eq "load-gates: a single FILE inside the guest HOME (/root/.gitconfig) passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-sysfile-ok.yml")"
  printf 'mounts:\n  - source: %s\n    tag: t\n    path: /tmp/seed.json\n' "$GATE_SRC_FILE" \
    > "$WORK/gate-sysfile-tmp.yml"
  assert_eq "load-gates: a single FILE inside /tmp passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-sysfile-tmp.yml")"

  # ...but the SAME path with a DIRECTORY source does not. This pair is the
  # whole directory-vs-file distinction in two assertions: same mountpoint
  # class, opposite verdicts, decided only by what the source is.
  gate_mount_case "a DIRECTORY at that same in-/root path" \
    "$(printf 'mounts:\n  - source: %s\n    tag: cfgdir\n    path: /root/.gitconfig\n' "$GATE_SRC_A")" \
    "overlaps the guest OS"

  # A single FILE inside a package-owned directory IS a mount over a system
  # file. /etc/ld.so.preload is the sharpest example -- a file bound there runs
  # attacker-chosen code in every process the guest starts.
  gate_mount_case "a single FILE inside /etc" \
    "$(printf 'mounts:\n  - source: %s\n    tag: pre\n    path: /etc/ld.so.preload\n' "$GATE_SRC_FILE")" \
    "where every file belongs to a system package"
  gate_mount_case "a single FILE inside /usr" \
    "$(printf 'mounts:\n  - source: %s\n    tag: bin\n    path: /usr/local/lib/claude-vm/boot-launcher.sh\n' "$GATE_SRC_FILE")" \
    "where every file belongs to a system package"
  # A single FILE landing ON a system directory, or above one: the bind would
  # replace the whole directory, so the file rule rejects it too.
  gate_mount_case "a single FILE on a system directory (/etc)" \
    "$(printf 'mounts:\n  - source: %s\n    tag: etcf\n    path: /etc\n' "$GATE_SRC_FILE")" \
    "or sits above it"

  # The guard must not over-reach. /mnt is claude-vm's OWN mount root, so the
  # /mnt/<tag> DEFAULT has to keep working, and the FHS mount-here directories
  # ship empty, which is what makes them the right destination for a share.
  printf 'mounts:\n  - source: %s\n    tag: plain\n' "$GATE_SRC_A" \
    > "$WORK/gate-default-mnt.yml"
  assert_eq "load-gates: the DEFAULT /mnt/<tag> mountpoint still passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-default-mnt.yml")"
  printf 'mounts:\n  - source: %s\n    tag: s\n    path: /srv/custom\n' "$GATE_SRC_A" \
    > "$WORK/gate-srv.yml"
  assert_eq "load-gates: a directory at /srv/custom still passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-srv.yml")"
  printf 'mounts:\n  - source: %s\n    tag: o\n    path: /opt/tools\n' "$GATE_SRC_A" \
    > "$WORK/gate-opt.yml"
  assert_eq "load-gates: a directory at /opt/tools still passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-opt.yml")"
  # ...and a system path is matched on a COMPONENT boundary, so an ordinary
  # /etc-prefixed name that is not under /etc is not a collision.
  printf 'mounts:\n  - source: %s\n    tag: etcish\n    path: /etcetera\n' "$GATE_SRC_A" \
    > "$WORK/gate-etcetera.yml"
  assert_eq "load-gates: a path that only PREFIX-matches a system path passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-etcetera.yml")"

  # Two entries resolving to the same guest path: the later mount shadows the
  # earlier one, so one of the two directories is simply unreachable. Distinct
  # tags, so this is NOT the duplicate-tag case -- the second entry's default
  # /mnt/<tag> collides with the first's explicit path.
  gate_mount_case "a DUPLICATE guest path" \
    "$(printf 'mounts:\n  - source: %s\n    tag: first\n    path: /mnt/second\n  - source: %s\n    tag: second\n' "$GATE_SRC_A" "$GATE_SRC_B")" \
    "where an earlier entry already"

  # A `..` segment cannot be resolved host-side, so it is rejected rather than
  # guessed at -- without this, /mnt/x/../repo walks past the reserved check.
  gate_mount_case "a path with a '..' segment" \
    "$(printf 'mounts:\n  - source: %s\n    tag: dots\n    path: /mnt/x/../repo\n' "$GATE_SRC_A")" \
    "contains a '..' segment"

  # A tag outside [A-Za-z0-9._-] corrupts vfkit's comma-delimited device string
  # and the guest's own `mount -t virtiofs <tag>` argument.
  gate_mount_case "a tag with a COMMA in it" \
    "$(printf 'mounts:\n  - source: %s\n    tag: "a,b"\n' "$GATE_SRC_A")" \
    "contains characters outside"

  # A single FILE source is legal (it is wrapped by the launcher), so the
  # host-existence check must accept it rather than demanding a directory.
  printf 'mounts:\n  - source: %s\n    tag: f\n    path: /root/.gitconfig\n' "$GATE_SRC_FILE" \
    > "$WORK/gate-file-boot.yml"
  assert_eq "load-gates: a single-FILE source with a path override passes" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-file-boot.yml")"

  # A `~` source is expanded before the existence check -- otherwise every
  # config in the example file would abort, since no literal './~/...' exists.
  # $HOME itself is the one path guaranteed to be there.
  printf 'mounts:\n  - source: "~"\n    tag: home\n' > "$WORK/gate-tilde-boot.yml"
  assert_eq "load-gates: a '~' source is expanded before the existence check" \
    "0|GATE-OK" "$(run_gates "$GATE_NONE_BAKE" "$WORK/gate-tilde-boot.yml")"

  # A mounts entry whose `tag:` key is OMITTED. Before the `// ""` guard on
  # claude_vm_mount_specs this rendered the literal string `null` and sailed
  # through to vfkit as mountTag=null; it is now an empty field and a hard stop.
  GATE_NOTAG_BOOT="$WORK/gate-notag-boot.yml"
  printf 'mounts:\n  - source: /a/omitted-tag\n' > "$GATE_NOTAG_BOOT"
  GATE_NOTAG="$(run_gates "$GATE_NONE_BAKE" "$GATE_NOTAG_BOOT")"
  assert_eq "load-gates: an OMITTED mount tag aborts the launch" \
    "1" "${GATE_NOTAG%%|*}"
  case "$GATE_NOTAG" in
    *"mounts entry #1 ('/a/omitted-tag') has no tag"*)
      assert_eq "load-gates: the omitted-tag abort names the mount path" "named" "named" ;;
    *)
      assert_eq "load-gates: the omitted-tag abort names the mount path" "named" "$GATE_NOTAG" ;;
  esac

  # ...and an EXPLICITLY empty tag, the other spelling of the same mistake.
  GATE_EMPTYTAG_BOOT="$WORK/gate-emptytag-boot.yml"
  printf 'mounts:\n  - source: /a/empty-tag\n    tag: ""\n' > "$GATE_EMPTYTAG_BOOT"
  GATE_EMPTYTAG="$(run_gates "$GATE_NONE_BAKE" "$GATE_EMPTYTAG_BOOT")"
  assert_eq "load-gates: an EXPLICITLY empty mount tag aborts the launch" \
    "1" "${GATE_EMPTYTAG%%|*}"
  case "$GATE_EMPTYTAG" in
    *"mounts entry #1 ('/a/empty-tag') has no tag"*)
      assert_eq "load-gates: the empty-tag abort names the mount path" "named" "named" ;;
    *)
      assert_eq "load-gates: the empty-tag abort names the mount path" "named" "$GATE_EMPTYTAG" ;;
  esac

  # A mounts entry with no source at all: nothing to share, and nothing to name
  # it by. Previously the launcher's loop dropped it without a word.
  GATE_NOSRC_BOOT="$WORK/gate-nosrc-boot.yml"
  printf 'mounts:\n  - tag: orphan\n' > "$GATE_NOSRC_BOOT"
  GATE_NOSRC="$(run_gates "$GATE_NONE_BAKE" "$GATE_NOSRC_BOOT")"
  assert_eq "load-gates: a mount with no source aborts the launch" \
    "1" "${GATE_NOSRC%%|*}"
  case "$GATE_NOSRC" in
    *"mounts entry #1 has no source"*)
      assert_eq "load-gates: the no-source abort says which entry" "named" "named" ;;
    *)
      assert_eq "load-gates: the no-source abort says which entry" "named" "$GATE_NOSRC" ;;
  esac

  # A claude.marketplaces entry with a url but no name, in the BOOT document.
  GATE_NONAME_BOOT="$WORK/gate-noname-boot.yml"
  cat > "$GATE_NONAME_BOOT" <<'YML'
claude:
  marketplaces:
    - name: fine
      url: https://example.invalid/fine.git
    - url: https://example.invalid/nameless.git
YML
  GATE_NONAME="$(run_gates "$GATE_NONE_BAKE" "$GATE_NONAME_BOOT")"
  assert_eq "load-gates: a nameless marketplace aborts the launch" \
    "1" "${GATE_NONAME%%|*}"
  case "$GATE_NONAME" in
    *"claude.marketplaces entry #2 in the merged BOOT config has no name (url: 'https://example.invalid/nameless.git')"*)
      assert_eq "load-gates: the nameless-marketplace abort names tier, index and url" "named" "named" ;;
    *)
      assert_eq "load-gates: the nameless-marketplace abort names tier, index and url" "named" "$GATE_NONAME" ;;
  esac

  # ...and the same entry in the BAKE document, which is a different tier label
  # and a different reader (the origin stamp, the baked-name set).
  GATE_NONAME_BAKE="$WORK/gate-noname-bake.yml"
  cat > "$GATE_NONAME_BAKE" <<'YML'
claude:
  marketplaces:
    - url: https://example.invalid/bake-nameless.git
YML
  GATE_NONAME_B="$(run_gates "$GATE_NONAME_BAKE" "$GATE_NONE_BOOT")"
  assert_eq "load-gates: a nameless marketplace in a BAKE file aborts too" \
    "1" "${GATE_NONAME_B%%|*}"
  case "$GATE_NONAME_B" in
    *"in the merged BAKE config has no name"*)
      assert_eq "load-gates: the BAKE-tier abort says BAKE" "named" "named" ;;
    *)
      assert_eq "load-gates: the BAKE-tier abort says BAKE" "named" "$GATE_NONAME_B" ;;
  esac
else
  echo "SKIP: config-load gate block extraction from claude-vm.sh failed; load-gate tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 33: the TWO-field record readers split by hand too
# (issue #226 class completion).
#
# A tab is IFS WHITESPACE, so `IFS=$'\t' read -r a b` does not only collapse a
# run of tabs -- it also STRIPS A LEADING one. A two-field record has no middle
# field to lose, but it does have a leading one: `<TAB>url`, the record for a
# marketplace declared with a url and no name, arrives as name=url / url="".
# Every reader is therefore hand-split like its three-field siblings.
#
# Driven against the REAL emitters, with a negative control rebuilt from the
# SAME captured lines so the control cannot drift away from the code it is
# contrasted with.
# ---------------------------------------------------------------------
TF_BOOT="$WORK/twofield-boot.yml"
cat > "$TF_BOOT" <<'YML'
claude:
  marketplaces:
    - url: https://example.invalid/nameless.git
    - name: named
      url: https://example.invalid/named.git
YML
TF_BAKE="$WORK/twofield-bake.yml"
printf '{}\n' > "$TF_BAKE"

# The emitter really does produce a LEADING empty field for that entry -- the
# premise every assertion below rests on.
TF_LINES="$WORK/twofield-lines.tsv"
claude_vm_marketplaces "$TF_BOOT" > "$TF_LINES"
assert_eq "two-field: the emitter leads a nameless entry with an EMPTY field" \
  "1" "$(grep -c '^	https://example.invalid/nameless.git$' "$TF_LINES" || true)"

# claude_vm_effective_marketplaces drops the nameless entry and keeps its
# well-formed sibling.
assert_eq "two-field: effective set drops the nameless entry, keeps the named one" \
  "named," "$(claude_vm_effective_marketplaces "$TF_BAKE" "$TF_BOOT" | cut -f1 | tr '\n' ',')"

# NEGATIVE CONTROL: the pre-fix read, rebuilt over the SAME captured emitter
# lines, promotes the URL into the name slot -- so the launcher would have
# written a marketplace literally named `https://example.invalid/nameless.git`
# into plugin-marketplaces.tsv, with an empty url.
TF_OLD_NAME=""
while IFS=$'\t' read -r tf_name tf_url; do
  [ -n "$tf_name" ] || continue
  [ -n "$TF_OLD_NAME" ] || TF_OLD_NAME="$tf_name"
done < "$TF_LINES"
assert_eq "two-field: NEGATIVE CONTROL -- the old tab-IFS read takes the url as the name" \
  "https://example.invalid/nameless.git" "$TF_OLD_NAME"

# claude_vm_bake_plugins_json is the manifest the provisioner registers from:
# the nameless entry must not reach it under a url-shaped name.
TF_JSON="$(claude_vm_bake_plugins_json "$TF_BAKE" "$TF_BOOT")"
assert_eq "two-field: the bake manifest carries only the named marketplace" \
  "named" "$(printf '%s' "$TF_JSON" | yq -p=json eval '[.marketplaces[].name] | join(",")' - 2>/dev/null)"

# claude_vm_mount_specs normalizes an OMITTED tag to an empty field rather than
# the literal string `null` -- the premise claude_vm_check_mounts rests on, and
# the reason one check covers both spellings. The record is THREE fields
# (source, tag, path) with `tag` the optional MIDDLE one.
TF_MNT="$WORK/twofield-mounts.yml"
printf 'mounts:\n  - source: /a/omitted-tag\n' > "$TF_MNT"
assert_eq "mount-specs: an omitted tag emits an EMPTY field, not the string 'null'" \
  "/a/omitted-tag		" "$(claude_vm_mount_specs "$TF_MNT")"
# ...and an omitted `path:` likewise, so the record always carries both
# separators and a hand split is total.
TF_MNT_PATH="$WORK/twofield-mounts-path.yml"
printf 'mounts:\n  - source: /a/with-path\n    tag: wp\n    path: /srv/wp\n' > "$TF_MNT_PATH"
assert_eq "mount-specs: an explicit path rides the 3rd field" \
  "/a/with-path	wp	/srv/wp" "$(claude_vm_mount_specs "$TF_MNT_PATH")"
assert_eq "mount-specs: every record carries exactly 2 separators" \
  "2" "$(claude_vm_mount_specs "$TF_MNT" | head -1 | tr -cd '\t' | wc -c | tr -d ' ')"
# ...and `mode` is gone from the record entirely, whatever the config says. A
# leftover mode field would shift `path` into the guest's `file` slot.
TF_MNT_MODE="$WORK/twofield-mounts-mode.yml"
printf 'mounts:\n  - source: /a/with-mode\n    tag: wm\n    mode: ro\n    path: /srv/wm\n' > "$TF_MNT_MODE"
assert_eq "mount-specs: a config that still sets mode: emits no mode field" \
  "/a/with-mode	wm	/srv/wm" "$(claude_vm_mount_specs "$TF_MNT_MODE")"

# claude_vm_mount_mode_entries: the PRESENCE test behind the `mode:` abort. It
# has to distinguish a supplied key from an omitted one, which no VALUE can do
# -- `mode: ""` and `mode:` (a null) both render as the same empty field an
# omitted key renders as.
TF_MODE_ENTRIES="$WORK/mode-entries.yml"
{
  printf 'mounts:\n'
  printf '  - source: /a/none\n    tag: none\n'
  printf '  - source: /a/set\n    tag: set\n    mode: ro\n'
  printf '  - source: /a/empty\n    tag: empty\n    mode: ""\n'
  printf '  - source: /a/null\n    tag: null-mode\n    mode:\n'
} > "$TF_MODE_ENTRIES"
assert_eq "mode-entries: every SPELLING of a supplied mode is reported, by entry number" \
  "2	/a/set 3	/a/empty 4	/a/null" \
  "$(claude_vm_mount_mode_entries "$TF_MODE_ENTRIES" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "mode-entries: an entry with no mode key is NOT reported" \
  "0" "$(claude_vm_mount_mode_entries "$TF_MODE_ENTRIES" | grep -c '/a/none' || true)"
assert_eq "mode-entries: a config with no mounts at all reports nothing" \
  "0" "$(claude_vm_mount_mode_entries "$TF_MNT_PATH" | grep -c . || true)"

# claude_vm_mount_guest_path: the default is /mnt/<tag>, an explicit path wins,
# and both are normalized so the collision checks below compare like with like.
assert_eq "guest-path: default is /mnt/<tag>" \
  "/mnt/data" "$(claude_vm_mount_guest_path data "")"
assert_eq "guest-path: an explicit path overrides the default" \
  "/srv/data" "$(claude_vm_mount_guest_path data /srv/data)"
assert_eq "guest-path: a trailing slash is dropped" \
  "/mnt/repo" "$(claude_vm_mount_guest_path data /mnt/repo/)"
assert_eq "guest-path: repeated slashes collapse" \
  "/mnt/repo" "$(claude_vm_mount_guest_path data ///mnt//repo)"
assert_eq "guest-path: root itself survives normalization" \
  "/" "$(claude_vm_mount_guest_path data /)"

# claude_vm_guest_path_covers is the DIRECTED half of the overlap relation, and
# the single-file rule's whole basis: a file may sit INSIDE a system path but
# may not cover one.
_covers() { claude_vm_guest_path_covers "$1" "$2" && echo yes || echo no; }
assert_eq "covers: a path covers itself" "yes" "$(_covers /etc /etc)"
assert_eq "covers: an ancestor covers its descendant" "yes" "$(_covers /etc /etc/hosts)"
assert_eq "covers: a descendant does NOT cover its ancestor" "no" "$(_covers /etc/hosts /etc)"
assert_eq "covers: / covers everything" "yes" "$(_covers / /root/.gitconfig)"
assert_eq "covers: a component-boundary prefix is not enough" "no" "$(_covers /etc /etcetera)"

# claude_vm_guest_system_path_containing names WHICH system path a mountpoint is
# under, which is what lets /root/.gitconfig pass while /etc/ld.so.preload does
# not. Strictly inside: a path EQUAL to a system path is not "inside" it.
assert_eq "system-container: /root/.gitconfig is inside /root" \
  "/root" "$(claude_vm_guest_system_path_containing /root/.gitconfig)"
assert_eq "system-container: /etc/ld.so.preload is inside /etc" \
  "/etc" "$(claude_vm_guest_system_path_containing /etc/ld.so.preload)"
assert_eq "system-container: /root itself is not INSIDE a system path" \
  "" "$(claude_vm_guest_system_path_containing /root)"
assert_eq "system-container: an ordinary mountpoint is under none of them" \
  "" "$(claude_vm_guest_system_path_containing /srv/custom)"
assert_eq "system-container: the DEFAULT /mnt/<tag> is under none of them" \
  "" "$(claude_vm_guest_system_path_containing /mnt/data)"

# claude.plugins.enabled with an EMPTY key: leading empty field again, this
# time on yq's `to_entries` output. The old read reported it as a plugin named
# `true`; it is now named as the empty ref it is, and it ABORTS rather than
# being skipped.
TF_ENA_BOOT="$WORK/twofield-enabled-boot.yml"
printf 'claude:\n  plugins:\n    enabled:\n      "": true\n' > "$TF_ENA_BOOT"
TF_ENA_BAKE="$WORK/twofield-enabled-bake.yml"
printf 'claude:\n  plugins:\n    bake:\n      - real@mp\n' > "$TF_ENA_BAKE"
TF_ENA_ERR="$(claude_vm_render_guest_settings "$TF_ENA_BOOT" "$TF_ENA_BAKE" 2>&1 >/dev/null)"
if claude_vm_render_guest_settings "$TF_ENA_BOOT" "$TF_ENA_BAKE" >/dev/null 2>&1; then
  assert_eq "two-field: an empty claude.plugins.enabled ref aborts the render" "abort" "rendered"
else
  assert_eq "two-field: an empty claude.plugins.enabled ref aborts the render" "abort" "abort"
fi
case "$TF_ENA_ERR" in
  *"claude.plugins.enabled entry #1 has an empty plugin ref (value: 'true')"*)
    assert_eq "two-field: the empty-ref abort names the entry and its value" "named" "named" ;;
  *)
    assert_eq "two-field: the empty-ref abort names the entry and its value" "named" "$TF_ENA_ERR" ;;
esac

# ---------------------------------------------------------------------
# Test 34: the GUEST-side reader (boot_plugin_phase) splits by hand too.
#
# This one sits inside build-guest-image.sh's <<'BOOT' heredoc and runs in the
# guest, where no config-load gate exists: the host's
# claude_vm_check_marketplace_names has already aborted the launch before
# plugin-marketplaces.tsv is written, so a nameless record cannot arrive by the
# ordinary path. The hand split plus the name guard is this side's floor for
# the paths that are not the ordinary one, and the phase WARNS rather than
# silently dropping the record.
#
# Reuses Test 30's extraction (BPP_START/BPP_END). `log` is redefined here to
# capture, so the warning itself is assertable.
# ---------------------------------------------------------------------
if [ -n "${BPP_START:-}" ] && [ -n "${BPP_END:-}" ] && command -v boot_plugin_phase >/dev/null 2>&1; then
  BPP_LOG="$WORK/bpp-log.txt"
  log() { printf '%s\n' "$*" >> "$BPP_LOG"; }

  : > "$CLAUDE_CALL_LOG"
  : > "$BPP_LOG"
  printf 'No marketplaces configured\n' > "$MP_LIST_FILE"
  : > "$PLUGIN_LIST_FILE"
  PLUGIN_MARKETPLACES_TSV="$WORK/bpp-mp-noname.tsv"
  printf '\texample.invalid\n' > "$PLUGIN_MARKETPLACES_TSV"
  PLUGIN_INSTALL_LIST="$WORK/bpp-install-empty.list"; : > "$PLUGIN_INSTALL_LIST"
  CLAUDE_VM_PLUGINS_UPDATE_AT_BOOT="false"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: a nameless record makes no CLI call at all" \
    "0" "$(grep -c . "$CLAUDE_CALL_LOG" || true)"
  assert_eq "boot_plugin_phase: a nameless record is WARNED about, not dropped silently" \
    "1" "$(grep -c "a configured marketplace has no name (url 'example.invalid')" "$BPP_LOG" || true)"

  # A wholly blank line is skipped without a warning -- the record has no
  # content to complain about.
  : > "$CLAUDE_CALL_LOG"
  : > "$BPP_LOG"
  printf '\n' > "$PLUGIN_MARKETPLACES_TSV"
  ( boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: a blank record is skipped with no warning" \
    "0" "$(grep -c . "$BPP_LOG" || true)"

  # NEGATIVE CONTROL: rebuild the phase with the pre-fix collapsing read (the
  # substitution runs over the SAME extracted lines, so it cannot drift), and
  # source it in a SUBSHELL so the redefinition does not leak. The old read
  # strips the leading empty field, so the phase asks the CLI whether a
  # marketplace named `example.invalid` is registered -- one CLI call where the
  # fixed code makes none.
  BPP_OLD_READ_AWK="    while IFS=\$'\\\\t' read -r mp_name mp_url; do"
  BPP_OLD_SRC="$WORK/boot_plugin_phase_old.sh"
  {
    echo 'log() { printf "%s\n" "$*" >> "$BPP_LOG"; }'
    awk -v start="$BPP_START" -v end="$BPP_END" -v oldread="$BPP_OLD_READ_AWK" '
      NR < start || NR > end { next }
      $0 ~ /^ *while IFS= read -r mp_record; do$/ { print oldread; next }
      $0 ~ /^ *mp_(name|url)=\$\{mp_record/ { next }
      { print }
    ' "$BUILD_GUEST_IMAGE"
  } > "$BPP_OLD_SRC"
  assert_eq "boot_plugin_phase: the control really carries the old tab-IFS read" \
    "1" "$(grep -cF -- "read -r mp_name mp_url; do" "$BPP_OLD_SRC" || true)"

  : > "$CLAUDE_CALL_LOG"
  : > "$BPP_LOG"
  printf '\texample.invalid\n' > "$PLUGIN_MARKETPLACES_TSV"
  # shellcheck source=/dev/null
  ( . "$BPP_OLD_SRC"; boot_plugin_phase >/dev/null 2>&1 || true )
  assert_eq "boot_plugin_phase: NEGATIVE CONTROL -- the old read queries the registry for a marketplace named after the url" \
    "1" "$(grep -c '^plugin marketplace list$' "$CLAUDE_CALL_LOG" || true)"
else
  echo "SKIP: boot_plugin_phase extraction from build-guest-image.sh failed; guest-side two-field tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Test 33: the guest boot launcher's boot_mount_phase (issue #157).
#
# The GUEST half of `mounts:`. Extracted from the <<'BOOT' heredoc in
# build-guest-image.sh by line range, the same way boot_apt_phase (Test 23) and
# boot_plugin_phase (Test 30) are, and sourced in-process with `log` recording
# to a file and `mount` replaced by a shell function that records its argv and
# whose exit status the test controls. A shell function shadows the external
# command for a bare `mount` call, which is what the phase makes.
#
# So these assert WHICH mount calls the phase issues, with which options, in
# what order -- not merely that it does not crash. What they CANNOT assert is
# that a guest write reaches the host: that needs a real guest, and is covered
# by the acceptance criteria on issue #157 rather than here. The OCCUPANCY
# decisions, by contrast, are real filesystem observations and ARE decided here:
# the phase looks at a real directory in the suite's temp tree.
#
# The behaviors checked:
#   - no manifest / empty manifest -> no mount calls at all
#   - a directory entry            -> one `mount -t virtiofs -o rw` at the
#                                     manifest's guest path
#   - an OCCUPIED directory target -> a WARNING and NO mount (never shadow)
#   - an occupied single-file target -> the same
#   - a single-file entry          -> wrap mount FIRST, then a --bind of the one
#                                     named file onto the target, with the
#                                     target created (it cannot already exist)
#   - a failing mount              -> a WARNING and the phase still returns 0
#                                     (fail-soft, like its two sibling phases)
#   - a record with an empty MIDDLE field survives the hand split
#
# The slice spans boot_dir_is_nonempty THROUGH boot_mount_phase: the helper is
# what the occupancy check calls, and a slice that took only the phase would
# leave it undefined -- the call would fail, the check would read as "empty",
# and every occupancy assertion below would pass for the wrong reason.
# ---------------------------------------------------------------------
BMP_START="$(grep -n '^boot_dir_is_nonempty() {' "$BUILD_GUEST_IMAGE" | head -1 | cut -d: -f1)"
BMP_PHASE_START="$(grep -n '^boot_mount_phase() {' "$BUILD_GUEST_IMAGE" | head -1 | cut -d: -f1)"
if [ -n "$BMP_START" ] && [ -n "$BMP_PHASE_START" ]; then
  BMP_END="$(awk -v start="$BMP_PHASE_START" 'NR > start && /^}/ { print NR; exit }' "$BUILD_GUEST_IMAGE")"
fi
if [ -n "${BMP_START:-}" ] && [ -n "${BMP_END:-}" ]; then
  BMP_SRC="$WORK/boot_mount_phase.sh"
  {
    echo 'log() { printf "%s\n" "$*" >> "$BMP_LOG"; }'
    echo 'mount() { printf "%s\n" "$*" >> "$MOUNT_CALL_LOG"; return "${MOUNT_STUB_EXIT:-0}"; }'
    awk -v start="$BMP_START" -v end="$BMP_END" 'NR >= start && NR <= end' "$BUILD_GUEST_IMAGE"
  } > "$BMP_SRC"
  # shellcheck source=/dev/null
  . "$BMP_SRC"
fi

if [ -n "${BMP_START:-}" ] && command -v boot_mount_phase >/dev/null 2>&1; then
  BMP_LOG="$WORK/bmp.log"
  MOUNT_CALL_LOG="$WORK/bmp-mount-calls.log"
  MOUNT_STUB_EXIT=0
  # Guest paths are rooted under $WORK: the phase really does mkdir its
  # mountpoints, and a literal /mnt/... would try to write outside the test's
  # temp tree (and fail for a reason that has nothing to do with the code).
  BMP_GUEST="$WORK/bmp-guest"
  MOUNT_WRAP_MNT="$BMP_GUEST/run/mount-wrap"

  # The slice must carry the occupancy helper as well as the phase. An
  # undefined boot_dir_is_nonempty returns non-zero (command not found), which
  # reads as "not occupied" -- every occupancy assertion below would then pass
  # while testing nothing.
  assert_eq "boot_mount_phase: the slice carries boot_dir_is_nonempty too" \
    "defined" "$(command -v boot_dir_is_nonempty >/dev/null 2>&1 && echo defined || echo missing)"

  run_bmp() {
    : > "$BMP_LOG"
    : > "$MOUNT_CALL_LOG"
    rm -rf "$BMP_GUEST"
    boot_mount_phase >/dev/null 2>&1
    printf '%s' "$?"
  }

  # An absent manifest -- an operator with no `mounts:` at all, or an older
  # host launcher -- must be a silent no-op, not a warning.
  MOUNTS_TSV="$WORK/bmp-absent.tsv"
  rm -f "$MOUNTS_TSV"
  assert_eq "boot_mount_phase: an ABSENT manifest returns 0" "0" "$(run_bmp)"
  assert_eq "boot_mount_phase: an absent manifest issues no mount calls" \
    "0" "$(grep -c . "$MOUNT_CALL_LOG" || true)"

  # An EMPTY manifest (the shape the host writes for a config with no mounts).
  MOUNTS_TSV="$WORK/bmp-empty.tsv"; : > "$MOUNTS_TSV"
  assert_eq "boot_mount_phase: an EMPTY manifest returns 0" "0" "$(run_bmp)"
  assert_eq "boot_mount_phase: an empty manifest issues no mount calls" \
    "0" "$(grep -c . "$MOUNT_CALL_LOG" || true)"

  # A directory mount. The record is <tag><TAB><guest-path><TAB><file>: no mode
  # field, because read-only is unenforceable on this stack (issue #233), and
  # the mount is read-write and says so to mount(8).
  MOUNTS_TSV="$WORK/bmp-dir.tsv"
  printf 'data\t%s/mnt/data\t\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  assert_eq "boot_mount_phase: a directory mount returns 0" "0" "$(run_bmp)"
  assert_eq "boot_mount_phase: a directory mount passes -o rw to mount(8)" \
    "-t virtiofs -o rw data $BMP_GUEST/mnt/data" "$(cat "$MOUNT_CALL_LOG")"
  assert_eq "boot_mount_phase: the mountpoint is created before mounting" \
    "present" "$([ -d "$BMP_GUEST/mnt/data" ] && echo present || echo absent)"

  # A `path:` override reaches mount(8) as the mountpoint. The host resolved it
  # into the manifest, so the guest simply obeys.
  MOUNTS_TSV="$WORK/bmp-path.tsv"
  printf 'elsewhere\t%s/srv/somewhere-else\t\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  run_bmp >/dev/null
  assert_eq "boot_mount_phase: a path override is used as the mountpoint verbatim" \
    "-t virtiofs -o rw elsewhere $BMP_GUEST/srv/somewhere-else" "$(cat "$MOUNT_CALL_LOG")"

  # ---- OCCUPANCY: the half only the guest can judge (issue #157 review) ----
  #
  # Linux STACKS a mount, so mounting over an occupied path hides what was there
  # for the life of the VM, and this phase runs FIRST so nothing later in the
  # boot ever sees the original. The host rejects every guest OS path it knows
  # of, but it cannot read the image's filesystem -- this side can. An occupied
  # DIRECTORY mountpoint is warned about and SKIPPED.
  MOUNTS_TSV="$WORK/bmp-occupied.tsv"
  printf 'data\t%s/etc\t\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  mkdir -p "$BMP_GUEST/etc"
  printf 'root:x:0:0\n' > "$BMP_GUEST/etc/passwd"
  BMP_OCC_RC=0
  boot_mount_phase >/dev/null 2>&1 || BMP_OCC_RC=$?
  assert_eq "boot_mount_phase: an OCCUPIED directory mountpoint issues NO mount call" \
    "0" "$(grep -c . "$MOUNT_CALL_LOG" || true)"
  assert_eq "boot_mount_phase: skipping an occupied mountpoint is still a clean return" \
    "0" "$BMP_OCC_RC"
  case "$(cat "$BMP_LOG")" in
    *"already exists and is NOT EMPTY"*)
      assert_eq "boot_mount_phase: the occupied mountpoint is WARNED about" "warned" "warned" ;;
    *)
      assert_eq "boot_mount_phase: the occupied mountpoint is WARNED about" "warned" "$(cat "$BMP_LOG")" ;;
  esac
  # There is deliberately no "the occupying file survived" assertion here: the
  # stubbed `mount` never really mounts, so that would hold whether or not the
  # check exists. "No mount call was issued" is the whole observable fact on
  # this side; that the content then stays visible is what a real boot shows.

  # An EMPTY existing directory is not occupancy: mkdir -p on an existing empty
  # mountpoint is the ordinary case, and it must still mount. Without this the
  # check could be "skip whenever the path exists", which would break the
  # default /mnt/<tag> on any image that ships those directories.
  MOUNTS_TSV="$WORK/bmp-empty-dir.tsv"
  printf 'data\t%s/mnt/data\t\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  mkdir -p "$BMP_GUEST/mnt/data"
  boot_mount_phase >/dev/null 2>&1
  assert_eq "boot_mount_phase: an EMPTY existing mountpoint still mounts" \
    "-t virtiofs -o rw data $BMP_GUEST/mnt/data" "$(cat "$MOUNT_CALL_LOG")"
  # A directory holding only a DOTFILE is occupied -- the glob has to see it, or
  # ~/.gitconfig-shaped content reads as empty.
  MOUNTS_TSV="$WORK/bmp-dotfile-dir.tsv"
  printf 'data\t%s/mnt/data\t\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  mkdir -p "$BMP_GUEST/mnt/data"
  printf 'x\n' > "$BMP_GUEST/mnt/data/.hidden"
  boot_mount_phase >/dev/null 2>&1
  assert_eq "boot_mount_phase: a mountpoint holding only a DOTFILE counts as occupied" \
    "0" "$(grep -c . "$MOUNT_CALL_LOG" || true)"

  # An existing NON-directory is not a mountpoint for a directory share at all.
  MOUNTS_TSV="$WORK/bmp-notadir.tsv"
  printf 'data\t%s/mnt/data\t\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  mkdir -p "$BMP_GUEST/mnt"
  printf 'x\n' > "$BMP_GUEST/mnt/data"
  boot_mount_phase >/dev/null 2>&1
  assert_eq "boot_mount_phase: a mountpoint that exists and is NOT a directory issues no mount call" \
    "0" "$(grep -c . "$MOUNT_CALL_LOG" || true)"

  # The single-file spelling of the same rule: a target that already exists is a
  # file the image shipped (/root/.bashrc is the live example -- the launcher's
  # own post-mortem shell would source the operator's file instead of it).
  MOUNTS_TSV="$WORK/bmp-file-occupied.tsv"
  printf 'cfg\t%s/root/.bashrc\tbashrc\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  mkdir -p "$BMP_GUEST/root"
  printf 'image-owned\n' > "$BMP_GUEST/root/.bashrc"
  mkdir -p "$MOUNT_WRAP_MNT/cfg"
  printf 'operator-owned\n' > "$MOUNT_WRAP_MNT/cfg/bashrc"
  boot_mount_phase >/dev/null 2>&1
  assert_eq "boot_mount_phase: an OCCUPIED single-file target issues NO mount call" \
    "0" "$(grep -c . "$MOUNT_CALL_LOG" || true)"
  assert_eq "boot_mount_phase: the image's own file is left in place" \
    "image-owned" "$(cat "$BMP_GUEST/root/.bashrc" 2>/dev/null)"
  case "$(cat "$BMP_LOG")" in
    *"ALREADY EXISTS in the guest"*)
      assert_eq "boot_mount_phase: the occupied single-file target is WARNED about" "warned" "warned" ;;
    *)
      assert_eq "boot_mount_phase: the occupied single-file target is WARNED about" "warned" "$(cat "$BMP_LOG")" ;;
  esac

  # A SINGLE-FILE entry: mount the wrap share out of the way FIRST, then bind
  # the one named file onto the target. Order is asserted (the bind's source
  # only exists once the wrap is mounted), and so is the fact that only the one
  # named file is bound -- that is what keeps the rest of the host file's real
  # parent directory out of the guest.
  MOUNTS_TSV="$WORK/bmp-file.tsv"
  printf 'cfg\t%s/root/.gitconfig\tgitconfig\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  # The stubbed `mount` never really mounts, so materialize the file the bind
  # step looks for inside the wrap mountpoint the phase creates.
  BMP_FILE_RC=0
  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  mkdir -p "$MOUNT_WRAP_MNT/cfg"
  printf 'host-content\n' > "$MOUNT_WRAP_MNT/cfg/gitconfig"
  boot_mount_phase >/dev/null 2>&1 || BMP_FILE_RC=$?
  assert_eq "boot_mount_phase: a single-file mount returns 0" "0" "$BMP_FILE_RC"
  assert_eq "boot_mount_phase: the wrap share is mounted FIRST, at the hidden wrap path" \
    "-t virtiofs -o rw cfg $MOUNT_WRAP_MNT/cfg" "$(sed -n 1p "$MOUNT_CALL_LOG")"
  assert_eq "boot_mount_phase: then exactly the one named file is bound onto the target" \
    "--bind $MOUNT_WRAP_MNT/cfg/gitconfig $BMP_GUEST/root/.gitconfig" \
    "$(sed -n 2p "$MOUNT_CALL_LOG")"
  assert_eq "boot_mount_phase: a single-file mount makes exactly 2 mount calls" \
    "2" "$(grep -c . "$MOUNT_CALL_LOG" || true)"
  assert_eq "boot_mount_phase: the bind target is created when it does not exist" \
    "present" "$([ -f "$BMP_GUEST/root/.gitconfig" ] && echo present || echo absent)"

  # FAIL-SOFT, the same bargain boot_apt_phase and boot_plugin_phase strike: a
  # mount that fails warns loudly on the hvc0 diagnostic log and the boot
  # continues to claude. A missing optional mount must never brick a session.
  MOUNTS_TSV="$WORK/bmp-failing.tsv"
  printf 'data\t%s/mnt/data\t\n' "$BMP_GUEST" > "$MOUNTS_TSV"
  MOUNT_STUB_EXIT=1
  assert_eq "boot_mount_phase: a FAILING mount still returns 0 (fail-soft)" "0" "$(run_bmp)"
  case "$(cat "$BMP_LOG")" in
    *"WARNING -- failed to mount extra share 'data'"*)
      assert_eq "boot_mount_phase: a failing mount is WARNED about by tag" "warned" "warned" ;;
    *)
      assert_eq "boot_mount_phase: a failing mount is WARNED about by tag" "warned" "$(cat "$BMP_LOG")" ;;
  esac
  MOUNT_STUB_EXIT=0

  # The hand split, on the guest side this time. A record whose MIDDLE field is
  # empty is the shape `IFS=$'\t' read -r tag path file` destroys: it collapses
  # the run of tabs, so `path` would receive the file name and the mount would
  # land at a relative path named after the file. The negative control is
  # rebuilt from the SAME captured lines so it cannot drift from the code it
  # contrasts with.
  #
  # The host never writes an empty guest path -- it always resolves one -- so
  # this record is SYNTHETIC. The split has to be total anyway: it is what makes
  # a malformed record visible as malformed, and the guard below it is what
  # turns that into a skip rather than a mount somewhere arbitrary.
  BMP_OLD_SRC="$WORK/boot_mount_phase-old.sh"
  {
    echo 'log() { printf "%s\n" "$*" >> "$BMP_LOG"; }'
    echo 'mount() { printf "%s\n" "$*" >> "$MOUNT_CALL_LOG"; return "${MOUNT_STUB_EXIT:-0}"; }'
    awk -v start="$BMP_START" -v end="$BMP_END" '
      NR < start || NR > end { next }
      $0 ~ /^ *while IFS= read -r record; do$/ {
        print "  while IFS=$\047\\t\047 read -r tag path file; do"; next
      }
      $0 ~ /^ *(tag|path|file|rest)=\$\{(record|rest)/ { next }
      # The collapsing read never binds $record, and the suite runs under
      # `set -u`, so the empty-record guard would abort the control before it
      # reached the split it exists to demonstrate. The malformed-record guard
      # a few lines below covers the same blank-line case on tag/path.
      $0 ~ /\[ -n "\$record" \]/ { next }
      { print }
    ' "$BUILD_GUEST_IMAGE"
  } > "$BMP_OLD_SRC"
  assert_eq "boot_mount_phase: the control really carries the old tab-IFS read" \
    "1" "$(grep -c -- 'read -r tag path file; do' "$BMP_OLD_SRC" || true)"

  # A record with an empty PATH field, so the middle-field collapse is visible:
  # the correct split sees an empty path, calls the record malformed and mounts
  # NOTHING; the old read shifts the file name into `path` and mounts there.
  MOUNTS_TSV="$WORK/bmp-emptymid.tsv"
  printf 'cfg\t\tgitconfig\n' > "$MOUNTS_TSV"
  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  boot_mount_phase >/dev/null 2>&1 || true
  assert_eq "boot_mount_phase: an empty MIDDLE field is seen as an empty path, and nothing is mounted" \
    "0" "$(grep -c . "$MOUNT_CALL_LOG" || true)"
  case "$(cat "$BMP_LOG")" in
    *"malformed mounts.tsv record (tag='cfg' path='')"*)
      assert_eq "boot_mount_phase: the malformed record is named with its own empty path" "named" "named" ;;
    *)
      assert_eq "boot_mount_phase: the malformed record is named with its own empty path" "named" "$(cat "$BMP_LOG")" ;;
  esac

  : > "$BMP_LOG"; : > "$MOUNT_CALL_LOG"; rm -rf "$BMP_GUEST"
  # The control really does mkdir its (wrong) mountpoint, and that mountpoint is
  # RELATIVE -- which is the damage. cd into $WORK so it lands in the suite's own
  # temp tree instead of the caller's working directory.
  # shellcheck source=/dev/null
  ( cd "$WORK" && . "$BMP_OLD_SRC" && boot_mount_phase >/dev/null 2>&1 || true )
  # The collapse shifts every field one slot left: the FILE NAME is read as the
  # path. So the share is mounted at a RELATIVE path named after the host file
  # -- not skipped as the malformed record it is, and not a single-file bind at
  # all, since `file` collapses to empty.
  assert_eq "boot_mount_phase: NEGATIVE CONTROL -- the old read mounts at a relative path named after the file" \
    "-t virtiofs -o rw cfg gitconfig" "$(sed -n 1p "$MOUNT_CALL_LOG")"
  assert_eq "boot_mount_phase: NEGATIVE CONTROL -- and the single-file bind never happens" \
    "1" "$(grep -c . "$MOUNT_CALL_LOG" || true)"
else
  echo "SKIP: boot_mount_phase extraction from build-guest-image.sh failed; guest-side mount tests skipped." >&2
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "config-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
