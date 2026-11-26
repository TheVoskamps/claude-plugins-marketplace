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
# `security find-generic-password ... -w` -> exit $SEC_RC, default nonzero (not
# logged in). The service it was asked for (the `-s` value) is appended to
# $SEC_LOG when that is set, so a case can assert which Keychain item the
# entry point checked -- or that it checked none.
cat > "$STUBBIN/security" <<'STUB'
#!/usr/bin/env bash
if [ -n "${SEC_LOG:-}" ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-s" ]; then printf '%s\n' "$2" >> "$SEC_LOG"; fi
    shift
  done
fi
exit "${SEC_RC:-1}"
STUB
chmod +x "$STUBBIN/security"

GLOBAL_DIR="$WORK/gconfig"
mkdir -p "$GLOBAL_DIR"

# run_bin [arg...] -> prints bin/claude-vm's stderr, with the global config
# dir pointed at $GLOBAL_DIR and `security` stubbed to fail. cwd is the repo
# so the repo-tier config paths resolve under $REPO/.claude-vm. $RUN_BIN, when
# set, is run in place of the real bin/claude-vm.
run_bin() {
  (
    cd "$REPO" || exit 99
    PATH="$STUBBIN:$PATH" \
    CLAUDE_VM_GLOBAL_CONFIG_DIR="$GLOBAL_DIR" \
      "${RUN_BIN:-$BIN}" "$@" 2>&1 1>/dev/null
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

# ---------------------------------------------------------------------
# --as <name> (issue #771). The fake $HOME holds one account, `work`; a
# CLAUDE_CONFIG_DIR naming a different directory is inherited by every case,
# so each one also shows that the variable decides nothing.
# ---------------------------------------------------------------------
: > "$GLOBAL_DIR/config-bake.yml"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude.work" "$WORK/inherited-config"
SEC_LOG="$WORK/security.log"
export SEC_LOG
export CLAUDE_CONFIG_DIR="$WORK/inherited-config"

# The service Claude Code itself uses for CLAUDE_CONFIG_DIR=<dir>, computed
# here independently of lib/credential.sh.
service_for() {
  printf 'Claude Code-credentials-%s' \
    "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:8])' "$1")"
}

# assert_exit <label> <expected> <actual>
assert_exit() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "ok   - $1"
  else FAIL=$((FAIL + 1)); echo "FAIL - $1"; echo "        expected: [$2]  actual: [$3]"; fi
}

if command -v python3 >/dev/null 2>&1; then
  # The Keychain check asks for the account's derived service, not the
  # default one and not the one CLAUDE_CONFIG_DIR would derive.
  : > "$SEC_LOG"
  OUT="$(HOME="$FAKE_HOME" SEC_RC=44 run_bin --as work)"
  assert_exit "--as work: the Keychain check queries the account's derived service" \
    "$(service_for "$FAKE_HOME/.claude.work")" "$(cat "$SEC_LOG")"
  assert_contains "--as work: a missing Keychain item is refused naming the account" "$OUT" "account 'work'"
  assert_contains "--as work: the refusal names the derived service" "$OUT" "$(service_for "$FAKE_HOME/.claude.work")"

  # Without --as the inherited CLAUDE_CONFIG_DIR is ignored: the default service.
  : > "$SEC_LOG"
  HOME="$FAKE_HOME" SEC_RC=44 run_bin > /dev/null
  assert_exit "no --as: the Keychain check queries the default service despite CLAUDE_CONFIG_DIR" \
    "Claude Code-credentials" "$(cat "$SEC_LOG")"
else
  echo "skip - derived-service cases (python3 not available)"
fi

# Refusals before any Keychain read: an invalid name, `backup`, a missing
# account directory, and a bare --as. Each names the account, and none reaches
# `security`.
for bad in "bad.name" "backup" "a/b"; do
  mkdir -p "$FAKE_HOME/.claude.$bad" 2>/dev/null
  : > "$SEC_LOG"
  OUT="$(HOME="$FAKE_HOME" SEC_RC=0 run_bin --as "$bad")"
  assert_contains "--as '$bad': refused as an invalid name" "$OUT" "not a valid account name"
  assert_contains "--as '$bad': the refusal names the account" "$OUT" "account '$bad'"
  assert_exit "--as '$bad': no Keychain read" "" "$(cat "$SEC_LOG")"
done
: > "$SEC_LOG"
OUT="$(HOME="$FAKE_HOME" SEC_RC=0 run_bin --as absent)"
assert_contains "--as absent: a missing account directory is refused" "$OUT" "has no config directory"
assert_contains "--as absent: the refusal names the account" "$OUT" "account 'absent'"
assert_exit "--as absent: no Keychain read" "" "$(cat "$SEC_LOG")"
assert_exit "--as absent: nothing is created in place of the account directory" \
  "no" "$([ -e "$FAKE_HOME/.claude.absent" ] && echo yes || echo no)"
: > "$SEC_LOG"
OUT="$(HOME="$FAKE_HOME" SEC_RC=0 run_bin --as)"
assert_contains "bare --as: refused for want of a name" "$OUT" "--as needs an account name"
assert_exit "bare --as: no Keychain read" "" "$(cat "$SEC_LOG")"

# ---------------------------------------------------------------------
# Forwarding. A copy of bin/claude-vm in a fake plugin tree whose launcher
# records its argv, one argument per line, so the cases can read exactly what
# the entry point passes on with the Keychain check stubbed to succeed.
# ---------------------------------------------------------------------
FAKE_PLUGIN="$WORK/plugin"
mkdir -p "$FAKE_PLUGIN/bin" "$FAKE_PLUGIN/payload/lib"
cp "$BIN" "$FAKE_PLUGIN/bin/claude-vm"
cp "$TEST_DIR/../lib/credential.sh" "$FAKE_PLUGIN/payload/lib/credential.sh"
ARGV_LOG="$WORK/launcher-argv"
export ARGV_LOG
cat > "$FAKE_PLUGIN/payload/claude-vm.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_LOG"
STUB
chmod +x "$FAKE_PLUGIN/bin/claude-vm" "$FAKE_PLUGIN/payload/claude-vm.sh"
TOPLEVEL="$(git -C "$REPO" rev-parse --show-toplevel)"

# argv_is <label> <expected-line>... -> the launcher saw exactly these args.
argv_is() {
  local label="$1"; shift
  local want
  want="$(printf '%s\n' "$@")"
  assert_exit "$label" "$want" "$(cat "$ARGV_LOG" 2>/dev/null)"
}

: > "$ARGV_LOG"
HOME="$FAKE_HOME" SEC_RC=0 RUN_BIN="$FAKE_PLUGIN/bin/claude-vm" run_bin --as work hello --as other > /dev/null
argv_is "--as work: passed on first, a later --as reaches claude unchanged, and the run name omits the leading one" \
  --as work "$TOPLEVEL" hello --as other --name "hello --as other widgets"

: > "$ARGV_LOG"
HOME="$FAKE_HOME" SEC_RC=0 RUN_BIN="$FAKE_PLUGIN/bin/claude-vm" run_bin hello > /dev/null
argv_is "no --as: the launcher gets the repo first, as before" \
  "$TOPLEVEL" hello --name "hello widgets"

: > "$ARGV_LOG"
HOME="$FAKE_HOME" SEC_RC=0 RUN_BIN="$FAKE_PLUGIN/bin/claude-vm" run_bin --as work > /dev/null
RUN_NAME_SEEN="$(sed -n '5p' "$ARGV_LOG")"
assert_exit "--as work alone: the launcher gets --as, the repo and a --name" \
  "--as|work|$TOPLEVEL|--name" "$(sed -n '1,4p' "$ARGV_LOG" | paste -sd'|' -)"
case "$RUN_NAME_SEEN" in
  *--as*|*work*) assert_exit "--as work alone: the date-stamped run name omits --as" "omitted" "$RUN_NAME_SEEN" ;;
  *" widgets")   assert_exit "--as work alone: the date-stamped run name omits --as" "omitted" "omitted" ;;
  *)             assert_exit "--as work alone: the date-stamped run name omits --as" "omitted" "$RUN_NAME_SEEN" ;;
esac
unset CLAUDE_CONFIG_DIR

echo ""
echo "bin-config-check-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
