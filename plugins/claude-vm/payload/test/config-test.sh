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
# Fixtures
# ---------------------------------------------------------------------
GLOBAL="$WORK/global.yml"
REPO="$WORK/repo.yml"

cat > "$GLOBAL" <<'YML'
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
    mode: ro
packages:
  bake:
    - jq
    - ripgrep
  install_at_boot:
    - htop
  update_at_boot: false
  apt_sources:
    - name: global-repo
      repo: "deb https://example.com/global stable main"
      key_url: https://example.com/global/key.asc
  add_apt_uris_to_allowlist: auto
claude:
  permission_mode: bypassPermissions
  permissions:
    allow:
      - "Bash(git:*)"
    ask:
      - "Bash(rm:*)"
    deny:
      - "Bash(sudo:*)"
  marketplaces:
    - name: global-mp
      url: https://example.com/global-mp
  plugins:
    bake:
      - foo@global-mp
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

cat > "$REPO" <<'YML'
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
    mode: ro
packages:
  bake:
    - ripgrep
    - fd-find
  install_at_boot:
    - build-essential
  update_at_boot: true
  apt_sources:
    - name: repo-registry
      repo: "deb https://example.com/repo stable main"
      key_url: https://example.com/repo/key.asc
  add_apt_uris_to_allowlist: always
claude:
  permission_mode: default
  permissions:
    allow:
      - "Bash(npm:*)"
    ask:
      - "Bash(rm:*)"
    deny:
      - "Bash(curl:*)"
  marketplaces:
    - name: repo-mp
      url: https://example.com/repo-mp
  plugins:
    bake:
      - baz@repo-mp
    install_at_boot:
      - bar@global-mp
    update_at_boot: true
    add_marketplace_uris_to_allowlist: always
    enabled:
      bar@global-mp: true
github:
  auth: host-token
YML

# ---------------------------------------------------------------------
# Test 1: scalar override -- repo wins, global fills gaps
# ---------------------------------------------------------------------
MERGED="$WORK/merged-both.yml"
claude_vm_merge_config "$GLOBAL" "$REPO" > "$MERGED"

assert_eq "scalar: repo overrides global (cpus)" \
  "8" "$(claude_vm_scalar "$MERGED" '.cpus' 'X')"
assert_eq "scalar: global fills gap (mem)" \
  "4096" "$(claude_vm_scalar "$MERGED" '.mem' 'X')"
assert_eq "scalar: repo overrides global (guest_image)" \
  "/repo/guest.raw" "$(claude_vm_scalar "$MERGED" '.guest_image' 'X')"
assert_eq "scalar: nested repo.mount repo wins" \
  "live" "$(claude_vm_scalar "$MERGED" '.repo.mount' 'X')"
assert_eq "scalar: nested proxy.cmd from global" \
  "global-proxy" "$(claude_vm_scalar "$MERGED" '.proxy.cmd' 'X')"
assert_eq "scalar: nested proxy.port from global" \
  "3128" "$(claude_vm_scalar "$MERGED" '.proxy.port' 'X')"

# ---------------------------------------------------------------------
# Test 2: list union -- egress.allow merged + de-duplicated
# ---------------------------------------------------------------------
# global: api.anthropic.com, github.com ; repo: github.com, cache.example.com
# union (sorted by yq unique): api.anthropic.com, cache.example.com, github.com
EGRESS="$(claude_vm_egress_hosts "$MERGED" | sort | tr '\n' ',' )"
assert_eq "list: egress.allow is unioned + de-duped" \
  "api.anthropic.com,cache.example.com,github.com," "$EGRESS"

# ---------------------------------------------------------------------
# Test 3: list union -- mounts merged (both global and repo entries)
# ---------------------------------------------------------------------
MOUNT_TAGS="$(claude_vm_mount_specs "$MERGED" | cut -f2 | sort | tr '\n' ',')"
assert_eq "list: mounts unioned (policy + data tags present)" \
  "data,policy," "$MOUNT_TAGS"
MOUNT_COUNT="$(claude_vm_mount_specs "$MERGED" | grep -c . )"
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
assert_eq "scalar: packages.update_at_boot repo wins (true)" \
  "true" "$(claude_vm_scalar "$MERGED" '.packages.update_at_boot' 'X')"
assert_eq "scalar: packages.add_apt_uris_to_allowlist repo wins (always)" \
  "always" "$(claude_vm_scalar "$MERGED" '.packages.add_apt_uris_to_allowlist' 'X')"
assert_eq "scalar: claude.permission_mode repo wins (default)" \
  "default" "$(claude_vm_scalar "$MERGED" '.claude.permission_mode' 'X')"
assert_eq "scalar: claude.plugins.update_at_boot repo wins (true)" \
  "true" "$(claude_vm_scalar "$MERGED" '.claude.plugins.update_at_boot' 'X')"
assert_eq "scalar: claude.plugins.add_marketplace_uris_to_allowlist repo wins (always)" \
  "always" "$(claude_vm_scalar "$MERGED" '.claude.plugins.add_marketplace_uris_to_allowlist' 'X')"
# claude.plugins.enabled is a scalar MAP merged repo-over-global PER KEY.
# global: {foo: true, bar: false}; repo: {bar: true}. Merged: foo stays true
# (global fills the gap), bar flips to true (repo wins on its own key).
assert_eq "map: claude.plugins.enabled[foo] from global (per-key gap fill)" \
  "true" "$(claude_vm_scalar "$MERGED" '.claude.plugins.enabled["foo@global-mp"]' 'X')"
assert_eq "map: claude.plugins.enabled[bar] repo wins (per-key override)" \
  "true" "$(claude_vm_scalar "$MERGED" '.claude.plugins.enabled["bar@global-mp"]' 'X')"
assert_eq "scalar: github.auth repo wins (host-token)" \
  "host-token" "$(claude_vm_scalar "$MERGED" '.github.auth' 'X')"

# ---------------------------------------------------------------------
# Test 3c: guest-capability schema (issue #103) -- nested list unions
# ---------------------------------------------------------------------
# packages.bake: global(jq, ripgrep) + repo(ripgrep, fd-find) -> 3 unique
PKG_BAKE="$(claude_vm_list_items "$MERGED" '.packages.bake' | sort | tr '\n' ',')"
assert_eq "list: packages.bake unioned + de-duped" \
  "fd-find,jq,ripgrep," "$PKG_BAKE"

# packages.install_at_boot: global(htop) + repo(build-essential) -> 2
PKG_INSTALL="$(claude_vm_list_items "$MERGED" '.packages.install_at_boot' | sort | tr '\n' ',')"
assert_eq "list: packages.install_at_boot unioned" \
  "build-essential,htop," "$PKG_INSTALL"

# packages.apt_sources: global(global-repo) + repo(repo-registry) -> 2
APT_SOURCE_NAMES="$(claude_vm_apt_sources "$MERGED" | cut -f1 | sort | tr '\n' ',')"
assert_eq "list: packages.apt_sources unioned" \
  "global-repo,repo-registry," "$APT_SOURCE_NAMES"

# claude.permissions.allow: global(Bash(git:*)) + repo(Bash(npm:*)) -> 2
PERM_ALLOW="$(claude_vm_list_items "$MERGED" '.claude.permissions.allow' | sort | tr '\n' ',')"
assert_eq "list: claude.permissions.allow unioned" \
  "Bash(git:*),Bash(npm:*)," "$PERM_ALLOW"

# claude.permissions.ask: identical entry in both layers -> de-dupes to 1
PERM_ASK_COUNT="$(claude_vm_list_items "$MERGED" '.claude.permissions.ask' | grep -c .)"
assert_eq "list: claude.permissions.ask de-dupes identical entry" "1" "$PERM_ASK_COUNT"

# claude.permissions.deny: global(Bash(sudo:*)) + repo(Bash(curl:*)) -> 2
PERM_DENY="$(claude_vm_list_items "$MERGED" '.claude.permissions.deny' | sort | tr '\n' ',')"
assert_eq "list: claude.permissions.deny unioned" \
  "Bash(curl:*),Bash(sudo:*)," "$PERM_DENY"

# claude.marketplaces: global(global-mp) + repo(repo-mp) -> 2
MP_NAMES="$(claude_vm_marketplaces "$MERGED" | cut -f1 | sort | tr '\n' ',')"
assert_eq "list: claude.marketplaces unioned" \
  "global-mp,repo-mp," "$MP_NAMES"

# claude.plugins.bake: global(foo@global-mp) + repo(baz@repo-mp) -> 2
PLUGIN_BAKE="$(claude_vm_list_items "$MERGED" '.claude.plugins.bake' | sort | tr '\n' ',')"
assert_eq "list: claude.plugins.bake unioned" \
  "baz@repo-mp,foo@global-mp," "$PLUGIN_BAKE"

# claude.plugins.install_at_boot: identical entry (bar@global-mp) in both -> 1
PLUGIN_INSTALL_COUNT="$(claude_vm_list_items "$MERGED" '.claude.plugins.install_at_boot' | grep -c .)"
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
BOOL_G="$WORK/bool-g.yml"; printf 'packages:\n  update_at_boot: true\nclaude:\n  plugins:\n    update_at_boot: true\n' > "$BOOL_G"
BOOL_R="$WORK/bool-r.yml"; printf 'packages:\n  update_at_boot: false\nclaude:\n  plugins:\n    update_at_boot: false\n' > "$BOOL_R"
MERGED_BOOL="$WORK/merged-bool.yml"
claude_vm_merge_config "$BOOL_G" "$BOOL_R" > "$MERGED_BOOL"
assert_eq "bool_scalar: packages.update_at_boot repo-wins explicit false survives" \
  "false" "$(claude_vm_bool_scalar "$MERGED_BOOL" '.packages.update_at_boot' 'FALLBACK')"
assert_eq "bool_scalar: claude.plugins.update_at_boot repo-wins explicit false survives" \
  "false" "$(claude_vm_bool_scalar "$MERGED_BOOL" '.claude.plugins.update_at_boot' 'FALLBACK')"

# ---------------------------------------------------------------------
# Test 3e: claude_vm_apt_sources / claude_vm_marketplaces -- missing
# optional field emits an EMPTY @tsv field, not the literal string
# "null" (issue #103 review finding).
# ---------------------------------------------------------------------
OPTIONAL_FIELD_YML="$WORK/optional-field.yml"
cat > "$OPTIONAL_FIELD_YML" <<'YML'
packages:
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
claude_vm_merge_config "$GLOBAL" "$WORK/does-not-exist.yml" > "$MERGED_G"
assert_eq "global-only: cpus from global" \
  "2" "$(claude_vm_scalar "$MERGED_G" '.cpus' 'X')"
assert_eq "global-only: egress count is 2" \
  "2" "$(claude_vm_egress_hosts "$MERGED_G" | grep -c .)"
# global's packages.update_at_boot is false; the yq `// ""` quirk for
# boolean false means the plain claude_vm_scalar accessor falls back to
# the caller default here -- this is claude_vm_scalar's DOCUMENTED
# limitation (see its header comment), not a bug in this accessor. The
# boolean-aware claude_vm_bool_scalar accessor (Test 3d below) is the
# one that must preserve explicit false; this assertion just pins
# claude_vm_scalar's known, unchanged behavior so a future edit doesn't
# silently "fix" it here and break the non-boolean scalar callers that
# rely on the `// ""` idiom.
assert_eq "global-only: packages.update_at_boot from global (false, plain scalar accessor falls back)" \
  "X" "$(claude_vm_scalar "$MERGED_G" '.packages.update_at_boot' 'X')"
assert_eq "global-only: claude.permission_mode from global" \
  "bypassPermissions" "$(claude_vm_scalar "$MERGED_G" '.claude.permission_mode' 'X')"
assert_eq "global-only: github.auth from global" \
  "none" "$(claude_vm_scalar "$MERGED_G" '.github.auth' 'X')"
assert_eq "global-only: packages.bake count is 2" \
  "2" "$(claude_vm_list_items "$MERGED_G" '.packages.bake' | grep -c .)"

# ---------------------------------------------------------------------
# Test 5: repo-only (global config absent) resolves cleanly
# ---------------------------------------------------------------------
MERGED_R="$WORK/merged-repo.yml"
claude_vm_merge_config "$WORK/does-not-exist.yml" "$REPO" > "$MERGED_R"
assert_eq "repo-only: cpus from repo" \
  "8" "$(claude_vm_scalar "$MERGED_R" '.cpus' 'X')"
assert_eq "repo-only: mem falls back to hardcoded default" \
  "$CLAUDE_VM_DEFAULT_MEM" "$(claude_vm_scalar "$MERGED_R" '.mem' "$CLAUDE_VM_DEFAULT_MEM")"
assert_eq "repo-only: claude.permission_mode from repo (default)" \
  "default" "$(claude_vm_scalar "$MERGED_R" '.claude.permission_mode' 'X')"
assert_eq "repo-only: github.auth from repo (host-token)" \
  "host-token" "$(claude_vm_scalar "$MERGED_R" '.github.auth' 'X')"
assert_eq "repo-only: packages.update_at_boot from repo (true)" \
  "true" "$(claude_vm_scalar "$MERGED_R" '.packages.update_at_boot' 'X')"

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
assert_eq "neither: packages.update_at_boot fallback (true)" \
  "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT" \
  "$(claude_vm_scalar "$MERGED_N" '.packages.update_at_boot' "$CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT")"
assert_eq "neither: packages.add_apt_uris_to_allowlist fallback (auto)" \
  "$CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST" \
  "$(claude_vm_scalar "$MERGED_N" '.packages.add_apt_uris_to_allowlist' "$CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST")"
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
assert_eq "neither: packages.bake is empty" \
  "0" "$(claude_vm_list_items "$MERGED_N" '.packages.bake' | grep -c .)"
assert_eq "neither: claude.permissions.allow is empty" \
  "0" "$(claude_vm_list_items "$MERGED_N" '.claude.permissions.allow' | grep -c .)"
assert_eq "neither: claude.marketplaces is empty" \
  "0" "$(claude_vm_marketplaces "$MERGED_N" | grep -c .)"

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
printf 'packages:\n  update_at_boot: false\n' > "$SCALAR_ONLY_G"
MERGED_SCALAR_ONLY="$WORK/merged-scalar-only.yml"
claude_vm_merge_config "$SCALAR_ONLY_G" "$WORK/does-not-exist.yml" > "$MERGED_SCALAR_ONLY"
assert_eq "prune: scalar-bearing packages map survives with only its scalar" \
  '{"packages":{"update_at_boot":false}}' \
  "$(yq eval -o=json -I=0 '.' "$MERGED_SCALAR_ONLY")"
assert_eq "prune: scalar-only merge has no claude key (never set)" \
  "false" "$(yq eval 'has("claude")' "$MERGED_SCALAR_ONLY")"

# The populated-both-layers fixture ($MERGED from Test 1) must be
# UNAFFECTED by pruning -- every list key it set stays present with its
# full unioned entry count (regression guard: pruning must not touch a
# non-empty list).
assert_eq "prune: populated merge still has packages.bake with entries" \
  "3" "$(claude_vm_list_items "$MERGED" '.packages.bake' | grep -c .)"
assert_eq "prune: populated merge still has claude.marketplaces with entries" \
  "2" "$(claude_vm_marketplaces "$MERGED" | grep -c .)"

# ---------------------------------------------------------------------
# Test 7: identical mount in both layers de-dupes to one entry
# ---------------------------------------------------------------------
DUP_G="$WORK/dup-g.yml"
DUP_R="$WORK/dup-r.yml"
cat > "$DUP_G" <<'YML'
mounts:
  - source: ~/shared
    tag: shared
    mode: ro
YML
cat > "$DUP_R" <<'YML'
mounts:
  - source: ~/shared
    tag: shared
    mode: ro
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
  claude_vm_merge_config "$GLOBAL" "$REPO" > "$OUT_A" || rc=1
  claude_vm_merge_config "$GLOBAL" "$REPO" > "$OUT_B" || rc=1
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
# claude_vm_render_guest_settings is pure (merged-config file -> settings.json
# on stdout). Cover the acceptance criteria that are verifiable host-side:
# config-only permissions, defaultMode from permission_mode, enabledPlugins from
# bake ++ install_at_boot (all default true), the claude.plugins.enabled
# per-key overrides, and the validation (boolean values, keys must be installed
# refs) that aborts on a typo. A tiny JSON reader (yq) inspects the emitted
# document.
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
    bake:
      - guardrails@thevoskamps
      - show-loaded-rules@thevoskamps
    install_at_boot:
      - issues@thevoskamps
    enabled:
      show-loaded-rules@thevoskamps: false
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
R_FULL="$(claude_vm_render_guest_settings "$S_FULL")"
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

# A ref in BOTH bake and install_at_boot collapses to one enabledPlugins entry.
S_DUP="$WORK/settings-dup.yml"
printf 'claude:\n  plugins:\n    bake:\n      - dup@mp\n    install_at_boot:\n      - dup@mp\n' > "$S_DUP"
R_DUP="$(claude_vm_render_guest_settings "$S_DUP")"
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
cat > "$S_ENA_OK" <<'YML'
claude:
  plugins:
    bake:
      - a@mp
      - b@mp
    enabled:
      a@mp: false
      b@mp: true
YML
if R_ENA_OK="$(claude_vm_render_guest_settings "$S_ENA_OK" 2>/dev/null)"; then
  assert_eq "enabled-validate: valid map renders (accept)" "accept" "accept"
  assert_eq "enabled-validate: a@mp disabled via false override" \
    "false" "$(get_json "$R_ENA_OK" '.enabledPlugins["a@mp"]')"
else
  assert_eq "enabled-validate: valid map renders (accept)" "accept" "reject"
fi

# Reject: an unknown key (names a plugin not in bake/install_at_boot) aborts.
S_ENA_BADKEY="$WORK/settings-enabled-badkey.yml"
cat > "$S_ENA_BADKEY" <<'YML'
claude:
  plugins:
    bake:
      - a@mp
    enabled:
      typo@mp: false
YML
if claude_vm_render_guest_settings "$S_ENA_BADKEY" >/dev/null 2>&1; then
  assert_eq "enabled-validate: unknown key aborts (reject)" "reject" "accept"
else
  assert_eq "enabled-validate: unknown key aborts (reject)" "reject" "reject"
fi

# Reject: a non-boolean value aborts.
S_ENA_BADVAL="$WORK/settings-enabled-badval.yml"
cat > "$S_ENA_BADVAL" <<'YML'
claude:
  plugins:
    bake:
      - a@mp
    enabled:
      a@mp: maybe
YML
if claude_vm_render_guest_settings "$S_ENA_BADVAL" >/dev/null 2>&1; then
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
packages:
  bake: [git, jq, ripgrep]
  apt_sources:
    - name: zeta
      repo: "deb https://z stable main"
      key_url: https://z/key.asc
    - name: alpha
      repo: "deb https://a stable main"
YML
BH_B="$WORK/bake-b.yml"; cat > "$BH_B" <<'YML'
packages:
  bake: [ripgrep, git, jq, git]
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
BH_MORE="$WORK/bake-more.yml"; printf 'packages:\n  bake: [git, jq, ripgrep, fd-find]\n' > "$BH_MORE"
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
packages:
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

# ---------------------------------------------------------------------
# Test 18: guest-image variant path derivation (issue #105).
#
# Reproduce the launcher's derivation logic (a bare block in claude-vm.sh, not
# a lib function) here against merged configs: explicit guest_image opts out;
# an empty bake config shares guest.raw; a bake config derives guest-<hash>.raw;
# and removing the override reverts to the shared guest.raw with no path churn.
# ---------------------------------------------------------------------
derive_image_path() {
  # Mirror claude-vm.sh's derivation: <merged-file> <default-image-dir>.
  local merged="$1" dir="$2" explicit
  explicit="$(claude_vm_scalar "$merged" '.guest_image' "")"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
  elif claude_vm_bake_config_is_empty "$merged"; then
    printf '%s\n' "$dir/guest.raw"
  else
    printf '%s\n' "$dir/guest-$(claude_vm_bake_hash "$merged").raw"
  fi
}
IMGDIR="/home/op/.config/claude-vm/images"

# Empty bake config -> shared guest.raw.
VP_EMPTY="$WORK/vp-empty.yml"; printf 'cpus: 4\n' > "$VP_EMPTY"
assert_eq "variant-path: no bake overrides -> shared guest.raw" \
  "$IMGDIR/guest.raw" "$(derive_image_path "$VP_EMPTY" "$IMGDIR")"

# Bake config -> guest-<hash>.raw (matching the standalone hash helper).
VP_BAKE="$WORK/vp-bake.yml"; printf 'packages:\n  bake: [git, jq]\n' > "$VP_BAKE"
VP_BAKE_HASH="$(claude_vm_bake_hash "$VP_BAKE")"
assert_eq "variant-path: bake overrides -> guest-<hash>.raw" \
  "$IMGDIR/guest-$VP_BAKE_HASH.raw" "$(derive_image_path "$VP_BAKE" "$IMGDIR")"

# Explicit guest_image opts out of variant derivation, even WITH bake items.
VP_OVERRIDE="$WORK/vp-override.yml"; printf 'guest_image: /custom/my.raw\npackages:\n  bake: [git]\n' > "$VP_OVERRIDE"
assert_eq "variant-path: explicit guest_image opts out (used verbatim)" \
  "/custom/my.raw" "$(derive_image_path "$VP_OVERRIDE" "$IMGDIR")"

# Removing the bake override reverts to the SAME shared guest.raw (warm path:
# no rebuild, since the path -- and thus the cached image + .version -- is the
# one an unchanged empty config already resolved to).
assert_eq "variant-path: removing bake override reverts to shared guest.raw" \
  "$(derive_image_path "$VP_EMPTY" "$IMGDIR")" "$IMGDIR/guest.raw"

# Two configs with the SAME bake set derive the SAME variant path (share one
# cached image), even declared in different orders.
VP_BAKE2="$WORK/vp-bake2.yml"; printf 'packages:\n  bake: [jq, git]\n' > "$VP_BAKE2"
assert_eq "variant-path: same bake set (reordered) derives same variant path" \
  "$(derive_image_path "$VP_BAKE" "$IMGDIR")" "$(derive_image_path "$VP_BAKE2" "$IMGDIR")"

# ---------------------------------------------------------------------
# Test 19: build-guest-image.sh --print-version bake-hash segment (issue #105).
#
# The launcher passes the canonical bake config to build-guest-image.sh via
# CLAUDE_VM_BAKE_CONFIG for both --print-version and --output, so the stamped
# version and the compared version agree. Exercise --print-version directly:
# empty/unset -> the legacy base version (share the global image, warm path);
# non-empty -> base+bake<hash>, stable and content-sensitive.
# ---------------------------------------------------------------------
BGI="$TEST_DIR/../build-guest-image.sh"
BASE_VER="$("$BGI" --print-version)"   # unset CLAUDE_VM_BAKE_CONFIG -> base version
assert_eq "print-version: unset bake config -> legacy base version (no +bake)" \
  "$BASE_VER" "$(CLAUDE_VM_BAKE_CONFIG='{"bake":[],"apt_sources":[]}' "$BGI" --print-version)"
# A non-empty bake config appends +bake<8hex>. Check the prefix and the
# +bake<8hex> suffix shape separately (a literal-prefix + regex-suffix check
# avoids escaping the base version's own metacharacters into a regex).
BGI_BAKED="$(CLAUDE_VM_BAKE_CONFIG='{"bake":["git","jq"],"apt_sources":[]}' "$BGI" --print-version)"
BGI_SUFFIX="${BGI_BAKED#"$BASE_VER"}"   # strip the exact base-version prefix
if [ "$BGI_SUFFIX" != "$BGI_BAKED" ] && printf '%s' "$BGI_SUFFIX" | grep -qE '^\+bake[0-9a-f]{8}$'; then
  assert_eq "print-version: baked config appends +bake<8hex> to base version" "ok" "ok"
else
  assert_eq "print-version: baked config appends +bake<8hex> to base version" "ok" "bad: [$BGI_BAKED]"
fi
# Same bake config -> same version (warm path: no spurious rebuild).
assert_eq "print-version: same bake config -> same version (warm path)" \
  "$BGI_BAKED" "$(CLAUDE_VM_BAKE_CONFIG='{"bake":["git","jq"],"apt_sources":[]}' "$BGI" --print-version)"
# Different bake config -> different version.
assert_ne "print-version: different bake config -> different version" \
  "$BGI_BAKED" "$(CLAUDE_VM_BAKE_CONFIG='{"bake":["git"],"apt_sources":[]}' "$BGI" --print-version)"
# The build-guest-image hash MATCHES the standalone lib hash for the same
# canonical bytes (the two sides agree by construction).
LIB_HASH_FOR_BAKED="$(claude_vm_bake_hash_from_json '{"bake":["git","jq"],"apt_sources":[]}')"
assert_eq "print-version: build-guest-image version embeds the lib bake-hash" \
  "$BASE_VER+bake$LIB_HASH_FOR_BAKED" "$BGI_BAKED"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "config-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
