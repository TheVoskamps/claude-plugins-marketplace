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
# Test 4: global-only (repo config absent) resolves cleanly
# ---------------------------------------------------------------------
MERGED_G="$WORK/merged-global.yml"
claude_vm_merge_config "$GLOBAL" "$WORK/does-not-exist.yml" > "$MERGED_G"
assert_eq "global-only: cpus from global" \
  "2" "$(claude_vm_scalar "$MERGED_G" '.cpus' 'X')"
assert_eq "global-only: egress count is 2" \
  "2" "$(claude_vm_egress_hosts "$MERGED_G" | grep -c .)"

# ---------------------------------------------------------------------
# Test 5: repo-only (global config absent) resolves cleanly
# ---------------------------------------------------------------------
MERGED_R="$WORK/merged-repo.yml"
claude_vm_merge_config "$WORK/does-not-exist.yml" "$REPO" > "$MERGED_R"
assert_eq "repo-only: cpus from repo" \
  "8" "$(claude_vm_scalar "$MERGED_R" '.cpus' 'X')"
assert_eq "repo-only: mem falls back to hardcoded default" \
  "$CLAUDE_VM_DEFAULT_MEM" "$(claude_vm_scalar "$MERGED_R" '.mem' "$CLAUDE_VM_DEFAULT_MEM")"

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
# Summary
# ---------------------------------------------------------------------
echo
echo "config-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
