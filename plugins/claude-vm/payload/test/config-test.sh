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
  hooks:
    parser: "on"
    no_background_agents: "on"
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
  hooks:
    parser: "off"
    no_background_agents: "off"
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
assert_eq "scalar: claude.hooks.parser repo wins (off)" \
  "off" "$(claude_vm_scalar "$MERGED" '.claude.hooks.parser' 'X')"
assert_eq "scalar: claude.hooks.no_background_agents repo wins (off)" \
  "off" "$(claude_vm_scalar "$MERGED" '.claude.hooks.no_background_agents' 'X')"
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
assert_eq "neither: claude.hooks.parser fallback (on)" \
  "$CLAUDE_VM_DEFAULT_CLAUDE_HOOKS_PARSER" \
  "$(claude_vm_scalar "$MERGED_N" '.claude.hooks.parser' "$CLAUDE_VM_DEFAULT_CLAUDE_HOOKS_PARSER")"
assert_eq "neither: claude.hooks.no_background_agents fallback (on)" \
  "$CLAUDE_VM_DEFAULT_CLAUDE_HOOKS_NO_BACKGROUND_AGENTS" \
  "$(claude_vm_scalar "$MERGED_N" '.claude.hooks.no_background_agents' "$CLAUDE_VM_DEFAULT_CLAUDE_HOOKS_NO_BACKGROUND_AGENTS")"
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
# claude_vm_render_guest_settings is pure (merged-config file + two resolved
# hook states -> settings.json on stdout). Cover the acceptance criteria that
# are verifiable host-side: config-only permissions, defaultMode from
# permission_mode, enabledPlugins from bake ++ install_at_boot, the hook-knob
# flips, and CLI-over-config precedence (exercised via the resolved state the
# caller passes in). A tiny JSON reader (yq) inspects the emitted document.
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
      - block-background-agents@thevoskamps
    install_at_boot:
      - issues@thevoskamps
YML

# get_json <settings-json> <yq-json-path> -- read one scalar from rendered JSON.
# Output is the RAW scalar (yq default output), so a string value comes back
# bare ("default", not "\"default\"") and a boolean/number bare too. `null` for
# an absent path.
get_json() {
  printf '%s' "$1" | yq -p=json eval "$2" - 2>/dev/null
}

# All hooks on: permissions verbatim, defaultMode bypassPermissions, all
# plugins true.
R_ON="$(claude_vm_render_guest_settings "$S_FULL" on on)"
assert_eq "render: defaultMode from permission_mode (bypassPermissions)" \
  "bypassPermissions" "$(get_json "$R_ON" '.permissions.defaultMode')"
assert_eq "render: permissions.allow verbatim from config" \
  "Bash(git:*)" "$(get_json "$R_ON" '.permissions.allow[0]')"
assert_eq "render: permissions.ask verbatim from config" \
  "Bash(rm:*)" "$(get_json "$R_ON" '.permissions.ask[0]')"
assert_eq "render: configured deny rule present" \
  "Bash(ssh-keygen:*)" "$(get_json "$R_ON" '.permissions.deny[0]')"
assert_eq "render: guardrails enabled when parser=on" \
  "true" "$(get_json "$R_ON" '.enabledPlugins["guardrails@thevoskamps"]')"
assert_eq "render: block-background-agents enabled when no-bg=on" \
  "true" "$(get_json "$R_ON" '.enabledPlugins["block-background-agents@thevoskamps"]')"
assert_eq "render: non-hook plugin (issues) always enabled" \
  "true" "$(get_json "$R_ON" '.enabledPlugins["issues@thevoskamps"]')"

# parser off -> only guardrails flips to false; the others stay true.
R_POFF="$(claude_vm_render_guest_settings "$S_FULL" off on)"
assert_eq "render: parser=off flips guardrails to false" \
  "false" "$(get_json "$R_POFF" '.enabledPlugins["guardrails@thevoskamps"]')"
assert_eq "render: parser=off leaves block-background-agents true" \
  "true" "$(get_json "$R_POFF" '.enabledPlugins["block-background-agents@thevoskamps"]')"

# no-background-agents off -> only that plugin flips.
R_NOFF="$(claude_vm_render_guest_settings "$S_FULL" on off)"
assert_eq "render: no-bg=off flips block-background-agents to false" \
  "false" "$(get_json "$R_NOFF" '.enabledPlugins["block-background-agents@thevoskamps"]')"
assert_eq "render: no-bg=off leaves guardrails true" \
  "true" "$(get_json "$R_NOFF" '.enabledPlugins["guardrails@thevoskamps"]')"

# Config-only permissions: the render NEVER reads host settings; with no
# claude.permissions.* set, the lists are empty (NOT populated from anywhere).
S_EMPTY="$WORK/settings-empty.yml"
printf 'claude:\n  permission_mode: default\n' > "$S_EMPTY"
R_EMPTY="$(claude_vm_render_guest_settings "$S_EMPTY" on on)"
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
R_NOMODE="$(claude_vm_render_guest_settings "$S_NOMODE" on on)"
assert_eq "render: absent permission_mode defaults to bypassPermissions" \
  "bypassPermissions" "$(get_json "$R_NOMODE" '.permissions.defaultMode')"

# A knob is meaningful only when its plugin is present: parser=off with no
# guardrails ref in the lists adds no entry (it does not fabricate one).
S_NOGUARD="$WORK/settings-noguard.yml"
printf 'claude:\n  plugins:\n    bake:\n      - issues@mp\n' > "$S_NOGUARD"
R_NOGUARD="$(claude_vm_render_guest_settings "$S_NOGUARD" off off)"
assert_eq "render: parser=off with no guardrails ref adds no entry" \
  "null" "$(get_json "$R_NOGUARD" '.enabledPlugins["guardrails@mp"]')"
assert_eq "render: only the present plugin is in enabledPlugins" \
  "1" "$(get_json "$R_NOGUARD" '.enabledPlugins | length')"

# guardrails hosted by any marketplace still matches (name-based match).
S_ALTMP="$WORK/settings-altmp.yml"
printf 'claude:\n  plugins:\n    bake:\n      - guardrails@some-other-mp\n' > "$S_ALTMP"
R_ALTMP="$(claude_vm_render_guest_settings "$S_ALTMP" off on)"
assert_eq "render: guardrails@<any-mp> flips regardless of marketplace" \
  "false" "$(get_json "$R_ALTMP" '.enabledPlugins["guardrails@some-other-mp"]')"

# ---------------------------------------------------------------------
# Test 15: --hook own-flag split (issue #104).
#
# claude_vm_split_hook_flags is pure: post-repo args -> 2-line override header
# + --ARGS-- sentinel + surviving args. Cover: absent flags pass through, both
# forms (two-token and =-joined) parse, the flags are stripped from the args,
# args with whitespace survive, and malformed flags abort (non-zero).
# ---------------------------------------------------------------------

# Absent flags -> both overrides '-', args pass through unchanged.
SPLIT_NONE="$(claude_vm_split_hook_flags --name "foo bar" --resume)"
assert_eq "hook-split: no flags -> parser override '-'" \
  "-" "$(printf '%s\n' "$SPLIT_NONE" | sed -n 1p)"
assert_eq "hook-split: no flags -> no-bg override '-'" \
  "-" "$(printf '%s\n' "$SPLIT_NONE" | sed -n 2p)"
# The surviving args (after the --ARGS-- sentinel on line 3): --name / foo bar / --resume
SPLIT_NONE_ARGS="$(printf '%s\n' "$SPLIT_NONE" | tail -n +4 | tr '\n' '|')"
assert_eq "hook-split: no flags -> args pass through (whitespace intact)" \
  "--name|foo bar|--resume|" "$SPLIT_NONE_ARGS"

# Two-token form, both knobs, mixed with a claude arg.
SPLIT_BOTH="$(claude_vm_split_hook_flags --hook parser=off --resume --hook no-background-agents=on)"
assert_eq "hook-split: two-token parser=off parsed" \
  "off" "$(printf '%s\n' "$SPLIT_BOTH" | sed -n 1p)"
assert_eq "hook-split: two-token no-background-agents=on parsed" \
  "on" "$(printf '%s\n' "$SPLIT_BOTH" | sed -n 2p)"
SPLIT_BOTH_ARGS="$(printf '%s\n' "$SPLIT_BOTH" | tail -n +4 | tr '\n' '|')"
assert_eq "hook-split: --hook flags stripped, only claude arg survives" \
  "--resume|" "$SPLIT_BOTH_ARGS"

# =-joined form.
SPLIT_EQ="$(claude_vm_split_hook_flags --hook=parser=on)"
assert_eq "hook-split: =-joined --hook=parser=on parsed" \
  "on" "$(printf '%s\n' "$SPLIT_EQ" | sed -n 1p)"

# Malformed: unknown hook name, bad state, and trailing --hook all abort.
if claude_vm_split_hook_flags --hook bogus=on >/dev/null 2>&1; then
  assert_eq "hook-split: unknown hook name aborts" "abort" "no-abort"
else
  assert_eq "hook-split: unknown hook name aborts" "abort" "abort"
fi
if claude_vm_split_hook_flags --hook parser=maybe >/dev/null 2>&1; then
  assert_eq "hook-split: bad state aborts" "abort" "no-abort"
else
  assert_eq "hook-split: bad state aborts" "abort" "abort"
fi
if claude_vm_split_hook_flags --name x --hook >/dev/null 2>&1; then
  assert_eq "hook-split: trailing --hook aborts" "abort" "no-abort"
else
  assert_eq "hook-split: trailing --hook aborts" "abort" "abort"
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "config-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
