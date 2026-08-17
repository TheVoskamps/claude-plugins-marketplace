#!/usr/bin/env bash
#
# claude-home-seed-test.sh -- regression test for issue #108's curated
# host ~/.claude seed.
#
# Two halves, on opposite sides of the host/guest seam:
#
#   HOST  (claude-vm.sh)          stages COPIES of the host's
#                                 ~/.claude/{CLAUDE.md, rules/, agents/,
#                                 skills/, keybindings.json} into
#                                 $CREDS_DIR/claude-home/.
#   GUEST (the boot launcher      copies those entries ADDITIVELY into
#          emitted by             $HOME/.claude/.
#          build-guest-image.sh)
#
# Both halves are plain shell loops over one fixed INCLUDE LIST, and the
# properties worth pinning are exactly the ones a reader cannot see by
# reading either loop alone:
#
#   - the include list is an include list -- a host ~/.claude entry that is
#     not on it (settings.json, projects/, history.jsonl, ...) never reaches
#     the guest, whatever else is going on;
#   - symlinks are DEREFERENCED, because a host ~/.claude is often a checkout
#     whose rules/ or skills/ points outside it, and a copied LINK would be a
#     dangling path in the guest (silent empty rules -- the exact failure this
#     feature exists to prevent);
#   - the guest copy is ADDITIVE and does not NEST -- `cp -R src dst` would
#     put the tree at dst/<name>/<name> on any path that already exists, and
#     the image's baked /root/.claude is never empty;
#   - an absent entry is tolerated on both sides (most hosts have no
#     keybindings.json), and an EMPTY seed still boots.
#
# So the test runs the REAL fragments, sliced verbatim out of claude-vm.sh
# and out of the launcher heredoc in build-guest-image.sh, against a fake
# host home and a fake guest home. It is the shipped code deciding, not a
# hand-copied reimplementation -- the same shape boot-launcher-test.sh uses
# for the shutdown decision.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/claude-home-seed-test.sh
#
# Requires: bash + awk (base tools). No VM, no network, no root.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$(cd "$TEST_DIR/.." && pwd)"
LAUNCHER_SRC="$PAYLOAD_DIR/claude-vm.sh"
BUILD="$PAYLOAD_DIR/build-guest-image.sh"

for f in "$LAUNCHER_SRC" "$BUILD"; do
  if [ ! -f "$f" ]; then
    echo "SKIP: $f not found." >&2
    exit 0
  fi
done

# Run each sliced fragment under the SAME interpreter running this harness, so
# `/bin/bash claude-home-seed-test.sh` on a stock macOS really exercises the
# fragments under bash 3.2 rather than under whatever `bash` PATH resolves to.
SHELL_UNDER_TEST="${BASH:-bash}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-homeseed-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo "ok   - $label"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $label"
    echo "        expected: [$expected]"
    echo "        actual:   [$actual]"
  fi
}

assert_file_is() {
  local label="$1" path="$2" expected="$3"
  if [ -f "$path" ]; then
    assert_eq "$label" "$expected" "$(cat "$path")"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $label"
    echo "        no such file: $path"
  fi
}

assert_absent() {
  local label="$1" path="$2"
  if [ -e "$path" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL - $label"
    echo "        expected NOT to exist: $path"
  else
    PASS=$((PASS + 1)); echo "ok   - $label"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); echo "ok   - $label" ;;
    *)           FAIL=$((FAIL + 1)); echo "FAIL - $label"
                 echo "        expected to contain: [$needle]" ;;
  esac
}

# ---------------------------------------------------------------------
# 1. Slice the two REAL fragments.
#
#    HOST: claude-vm.sh's staging loop, from the include-list assignment
#    through its `done`. It depends on $HOME and $CREDS_DIR and nothing else.
#
#    GUEST: the emitted boot launcher's install step, from the mount-path
#    assignment to the block comment that opens the next phase. It depends on
#    $CLAUDECREDS_MNT, $CRED_DIR and the launcher's own `log`.
# ---------------------------------------------------------------------
HOST_FRAGMENT="$WORK/host-stage-fragment.sh"
awk '
  /^CLAUDE_VM_HOME_SEED_ENTRIES=/ { cap=1 }
  cap { print }
  cap && /^done$/ { exit }
' "$LAUNCHER_SRC" > "$HOST_FRAGMENT"

LAUNCHER="$WORK/boot-launcher.sh"
awk '
  /^emit_boot_launcher\(\) \{/ { in_fn=1 }
  in_fn && /cat <<.BOOT.$/ { cap=1; next }
  cap && /^BOOT$/ { cap=0; in_fn=0 }
  cap { print }
' "$BUILD" > "$LAUNCHER"

GUEST_FRAGMENT="$WORK/guest-install-fragment.sh"
awk '
  /^MOUNTED_CLAUDE_HOME_SEED=/ { cap=1 }
  cap && /^# -----/ { exit }
  cap { print }
' "$LAUNCHER" > "$GUEST_FRAGMENT"

for pair in "host staging:$HOST_FRAGMENT" "guest install:$GUEST_FRAGMENT"; do
  label="${pair%%:*}"; path="${pair#*:}"
  if [ ! -s "$path" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL - could not slice the $label fragment"
    echo ""
    echo "claude-home-seed-test: $PASS passed, $FAIL failed"
    exit 1
  fi
done

assert_contains "host fragment is the real staging loop" \
  "$(cat "$HOST_FRAGMENT")" 'cp -RL'
assert_contains "guest fragment is the real install loop" \
  "$(cat "$GUEST_FRAGMENT")" 'MOUNTED_CLAUDE_HOME_SEED'

# ---------------------------------------------------------------------
# 2. Drive both fragments over a fake host home and a fake guest home.
#
#    run_seed <case-dir> populates nothing itself: the caller builds
#    <case>/home/.claude (the fake host ~/.claude) and <case>/guest/.claude
#    (the fake guest $HOME/.claude, pre-populated to test additivity), then
#    this runs HOST staging into <case>/creds/claude-home and GUEST install
#    out of it. Guest output (the `log` lines) lands on stdout.
# ---------------------------------------------------------------------
run_seed() {
  local case_dir="$1"
  mkdir -p "$case_dir/creds" "$case_dir/guest/.claude"
  HOME="$case_dir/home" CREDS_DIR="$case_dir/creds" \
    "$SHELL_UNDER_TEST" -c 'set -euo pipefail; . "$1"' _ "$HOST_FRAGMENT" 2>"$case_dir/host.err"
  CLAUDECREDS_MNT="$case_dir/creds" CRED_DIR="$case_dir/guest/.claude" \
    "$SHELL_UNDER_TEST" -c 'set -euo pipefail; log() { printf "%s\n" "$*"; }; . "$1"' \
      _ "$GUEST_FRAGMENT" 2>"$case_dir/guest.err"
}

# --- Case A: a full host ~/.claude, with excluded neighbours ----------
A="$WORK/case-a"
mkdir -p "$A/home/.claude/rules" "$A/home/.claude/agents" \
         "$A/home/.claude/skills/deep" "$A/home/.claude/projects" \
         "$A/home/.claude/todos" "$A/home/.claude/statsig"
printf 'global rules\n'   > "$A/home/.claude/CLAUDE.md"
printf 'core\n'           > "$A/home/.claude/rules/core-principles.md"
printf 'an agent\n'       > "$A/home/.claude/agents/dev.md"
printf 'a skill\n'        > "$A/home/.claude/skills/deep/SKILL.md"
printf 'keys\n'           > "$A/home/.claude/keybindings.json"
# Everything below is on the EXCLUSION side and must never reach the guest.
printf 'HOST POLICY\n'    > "$A/home/.claude/settings.json"
printf 'host session\n'   > "$A/home/.claude/history.jsonl"
printf 'host project\n'   > "$A/home/.claude/projects/p.json"
printf 'host todo\n'      > "$A/home/.claude/todos/t.json"
printf 'host statsig\n'   > "$A/home/.claude/statsig/s.json"
# The guest home is NOT empty -- the image bakes plugins/ -- and additivity
# must leave a pre-existing sibling inside a seeded directory alone.
mkdir -p "$A/guest/.claude/plugins" "$A/guest/.claude/skills"
printf 'baked plugin\n'   > "$A/guest/.claude/plugins/marketplace.json"
printf 'baked skill\n'    > "$A/guest/.claude/skills/baked.md"
A_LOG="$(run_seed "$A")"

assert_file_is "host CLAUDE.md reaches the guest" \
  "$A/guest/.claude/CLAUDE.md" "global rules"
assert_file_is "host rules/ reaches the guest" \
  "$A/guest/.claude/rules/core-principles.md" "core"
assert_file_is "host agents/ reaches the guest" \
  "$A/guest/.claude/agents/dev.md" "an agent"
assert_file_is "host skills/ reaches the guest, nested dirs and all" \
  "$A/guest/.claude/skills/deep/SKILL.md" "a skill"
assert_file_is "host keybindings.json reaches the guest" \
  "$A/guest/.claude/keybindings.json" "keys"

# The include list is an INCLUDE list: nothing off it is staged or installed,
# at either end. settings.json is the load-bearing one -- the guest's is
# RENDERED from config, so a host copy landing here would silently replace the
# operator's configured VM posture with their host posture.
assert_absent "host settings.json is not staged"      "$A/creds/claude-home/settings.json"
assert_absent "host settings.json never reaches the guest" \
  "$A/guest/.claude/settings.json"
assert_absent "host projects/ never reaches the guest"     "$A/guest/.claude/projects"
assert_absent "host history.jsonl never reaches the guest" "$A/guest/.claude/history.jsonl"
assert_absent "host todos/ never reaches the guest"        "$A/guest/.claude/todos"
assert_absent "host statsig/ never reaches the guest"      "$A/guest/.claude/statsig"

# ADDITIVE, and specifically NOT nesting: `cp -R src dst` (rather than
# `cp -R src/. dst/`) would land the tree at .claude/skills/skills on a path
# that already exists, and the guest's ~/.claude always already exists.
assert_file_is "baked plugins/ survives the seed" \
  "$A/guest/.claude/plugins/marketplace.json" "baked plugin"
assert_file_is "a pre-existing file inside a seeded dir survives" \
  "$A/guest/.claude/skills/baked.md" "baked skill"
assert_absent "seeded skills/ is not nested one level deeper" \
  "$A/guest/.claude/skills/skills"
assert_absent "seeded rules/ is not nested one level deeper" \
  "$A/guest/.claude/rules/rules"

assert_contains "guest logs which entries it seeded" "$A_LOG" "seeded host working rules"

# --- Case B: symlinked rules/ and skills/ (the ~/.claude-is-a-checkout host)
# `cp -R` without -L would copy the LINKS, and their targets sit outside the
# staged tree, so the guest would get two dangling paths and no rules at all.
B="$WORK/case-b"
mkdir -p "$B/home/.claude" "$B/elsewhere/rules" "$B/elsewhere/skills"
printf 'linked rule\n'  > "$B/elsewhere/rules/core.md"
printf 'linked skill\n' > "$B/elsewhere/skills/s.md"
ln -s "$B/elsewhere/rules"  "$B/home/.claude/rules"
ln -s "$B/elsewhere/skills" "$B/home/.claude/skills"
printf 'linked home\n' > "$B/home/.claude/CLAUDE.md"
run_seed "$B" > /dev/null

assert_file_is "a symlinked rules/ is dereferenced into real content" \
  "$B/guest/.claude/rules/core.md" "linked rule"
assert_file_is "a symlinked skills/ is dereferenced into real content" \
  "$B/guest/.claude/skills/s.md" "linked skill"
if [ -L "$B/guest/.claude/rules" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL - the guest's rules/ is a symlink, not a real directory"
else
  PASS=$((PASS + 1)); echo "ok   - the guest's rules/ is a real directory"
fi

# --- Case C: a sparse host (no keybindings.json, no agents/) ----------
# Absence is silent and must not fail either side.
C="$WORK/case-c"
mkdir -p "$C/home/.claude"
printf 'only a claude.md\n' > "$C/home/.claude/CLAUDE.md"
C_LOG="$(run_seed "$C")"
assert_file_is "a sparse host still seeds what it has" \
  "$C/guest/.claude/CLAUDE.md" "only a claude.md"
assert_absent "an absent keybindings.json is simply not there" \
  "$C/guest/.claude/keybindings.json"
assert_eq "a sparse host produces no host-side warning" "" "$(cat "$C/host.err")"
assert_contains "the guest still reports what it seeded" "$C_LOG" "CLAUDE.md"

# --- Case D: a host with NO ~/.claude at all --------------------------
# The empty seed is the boot-critical case: it must produce a clean run, not
# an abort, because this layer is a convenience and never a gate.
D="$WORK/case-d"
mkdir -p "$D/home"
D_LOG="$(run_seed "$D")"
assert_contains "an empty seed logs that the guest has no working rules" \
  "$D_LOG" "no host working rules to seed"
assert_eq "an empty seed leaves no host-side error output" "" "$(cat "$D/host.err")"
assert_eq "an empty seed leaves no guest-side error output" "" "$(cat "$D/guest.err")"

echo ""
echo "claude-home-seed-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
