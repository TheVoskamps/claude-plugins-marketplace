#!/usr/bin/env bash
#
# bin-config-check-test.sh -- regression test for issue #179 real-boot defect
# #3: bin/claude-vm's global-config presence check.
#
# Before the fix, bin/claude-vm checked for the pre-#179 single-file
# ~/.config/claude-vm/config.yml and printed "no global config found ...
# proceeding with built-in defaults" on EVERY launch, even when the migrated
# config-bake.yml / config-boot.yml pair was present -- a false message. The
# fix teaches the check the four-file bake/boot schema and routes a genuine
# leftover config.yml into a MIGRATION pointer instead of the "no config"
# message.
#
# This test drives the REAL bin/claude-vm up to (but not through) the launcher
# exec: it stubs `security` to report "not logged in" so the script prints the
# step-4 config message and then exits at the step-5 Keychain check, BEFORE it
# would exec the launcher / boot a VM. We assert on the step-4 stderr for each
# of the three config states (pair present / legacy leftover / nothing).
#
# Run directly:
#
#   plugins/claude-vm/payload/test/bin-config-check-test.sh
#
# Requires: git (to make the throwaway repo bin/claude-vm insists on). Skips if
# absent.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$TEST_DIR/../../bin/claude-vm"

if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not available; bin config-check test skipped." >&2
  exit 0
fi
if [ ! -x "$BIN" ]; then
  echo "SKIP: bin/claude-vm not executable at $BIN." >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-binconf-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); echo "ok   - $label" ;;
    *)           FAIL=$((FAIL + 1)); echo "FAIL - $label"
                 echo "        expected to contain: [$needle]"
                 echo "        actual stderr:"
                 printf '%s\n' "$haystack" | sed 's/^/          /' ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) FAIL=$((FAIL + 1)); echo "FAIL - $label"
                 echo "        expected NOT to contain: [$needle]" ;;
    *)           PASS=$((PASS + 1)); echo "ok   - $label" ;;
  esac
}

# ---------------------------------------------------------------------
# A throwaway git repo with an origin (bin/claude-vm requires both), and a
# stubbed `security` on PATH ahead of the real one so the Keychain check fails
# ("not logged in") and the script exits BEFORE the launcher exec.
# ---------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin "https://example.invalid/acme/widgets.git"

STUBBIN="$WORK/stubbin"
mkdir -p "$STUBBIN"
# `security find-generic-password ... -w` -> nonzero (not logged in). Any other
# security invocation also returns nonzero; the script only calls the -w form.
cat > "$STUBBIN/security" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUBBIN/security"

GLOBAL_DIR="$WORK/gconfig"
mkdir -p "$GLOBAL_DIR"

# run_bin <label> -> prints bin/claude-vm's stderr, with the global config dir
# pointed at $GLOBAL_DIR and `security` stubbed to fail. cwd is the repo so the
# repo-tier config paths resolve under $REPO/.claude-vm.
run_bin() {
  (
    cd "$REPO" || exit 99
    PATH="$STUBBIN:$PATH" \
    CLAUDE_VM_GLOBAL_CONFIG_DIR="$GLOBAL_DIR" \
      "$BIN" 2>&1 1>/dev/null
  )
}

# ---------------------------------------------------------------------
# Case (b): the bake/boot pair is present -> NO "no config" message, NO
# migration message. This is the exact false-positive defect #3 fixed.
# ---------------------------------------------------------------------
: > "$GLOBAL_DIR/config-bake.yml"
: > "$GLOBAL_DIR/config-boot.yml"
OUT="$(run_bin)"
assert_not_contains "pair present: no 'no global config' message" "$OUT" "no global config found"
assert_not_contains "pair present: no migration message" "$OUT" "legacy single-file config"

# ---------------------------------------------------------------------
# Case (a): a leftover single-file config.yml -> the MIGRATION pointer, NOT the
# "no config" message. (Remove the pair first so only the legacy file is present.)
# ---------------------------------------------------------------------
rm -f "$GLOBAL_DIR/config-bake.yml" "$GLOBAL_DIR/config-boot.yml"
: > "$GLOBAL_DIR/config.yml"
OUT="$(run_bin)"
assert_contains "legacy present: prints migration pointer" "$OUT" "legacy single-file config"
assert_not_contains "legacy present: no false 'no config' message" "$OUT" "no global config found"
rm -f "$GLOBAL_DIR/config.yml"

# ---------------------------------------------------------------------
# Case (c): nothing at all -> the create-one nicety ("no global config").
# ---------------------------------------------------------------------
OUT="$(run_bin)"
assert_contains "empty: prints 'no global config' create-one nicety" "$OUT" "no global config found"
assert_not_contains "empty: no migration pointer" "$OUT" "legacy single-file config"

# ---------------------------------------------------------------------
# Case (a'): a leftover REPO-tier config.yml (not global) also routes to the
# migration pointer -- the check covers both tiers.
# ---------------------------------------------------------------------
mkdir -p "$REPO/.claude-vm"
: > "$REPO/.claude-vm/config.yml"
OUT="$(run_bin)"
assert_contains "repo legacy present: prints migration pointer" "$OUT" "legacy single-file config"
rm -f "$REPO/.claude-vm/config.yml"

echo ""
echo "bin-config-check-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
