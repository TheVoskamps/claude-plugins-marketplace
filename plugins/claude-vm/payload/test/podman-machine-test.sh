#!/usr/bin/env bash
#
# podman-machine-test.sh -- the launcher's own podman machine management
# (issue #215).
#
# Two things are under test, and they need different harnesses:
#
#   1. The three helpers in lib/config.sh -- claude_vm_podman_machine_probe,
#      claude_vm_ensure_podman_machine, claude_vm_stop_podman_machine --
#      driven against a stub `podman` on PATH that keeps real state, so an
#      init/start/stop sequence is observable as a sequence rather than as
#      one call at a time.
#
#   2. The SCOPING: only a launch that builds the guest image may touch
#      podman. That is a property of the launcher, not of a helper, so the
#      build-or-reuse block is sliced out of claude-vm.sh with awk and RUN
#      (the same extract-and-run shape config-test.sh uses on
#      build-guest-image.sh's apt functions). Asserting it by grepping the
#      source would pass on a block whose condition is inverted.
#
# No VM, no network, no host mutation: the stub podman never provisions
# anything. Requires python3 (which the helper itself parses JSON with, and
# which macOS ships).
#
# Run directly:
#
#   plugins/claude-vm/payload/test/podman-machine-test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/config.sh"
LAUNCHER="$TEST_DIR/../claude-vm.sh"

# shellcheck source=../lib/config.sh
. "$LIB"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available; podman machine tests skipped." >&2
  exit 0
fi

WORK="$(claude_vm_mktemp -d claude-vm-podman-test)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

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
# The stub podman. It is STATEFUL -- `machine init` creates a machine,
# `machine start`/`machine stop` flip its Running flag, and `machine list`
# renders the current state as the JSON podman emits -- because the helper
# re-probes after an init and would pass against a stateless stub that
# always answered the same list.
#
# State lives in $PODMAN_STUB_DIR:
#   machines     one `name:running:default` record per line (`:`, not a tab:
#                a colon cannot appear in a podman machine name, and this
#                keeps the fixture out of the tab-record hazards the rest of
#                the plugin avoids)
#   log          one line per invocation, the argv joined by spaces
#   info-broken  present => `podman info` fails even with a running machine
# ---------------------------------------------------------------------
STUB_BIN="$WORK/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/podman" <<'EOF'
#!/usr/bin/env bash
set -u
D="$PODMAN_STUB_DIR"
echo "$*" >> "$D/log"

render_list() {
  python3 -c '
import json, sys
out = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    name, running, default = line.split(":")
    out.append({"Name": name, "Running": running == "true", "Default": default == "true"})
print(json.dumps(out))
' "$D/machines"
}

set_running() {
  python3 -c '
import sys
path, target, state = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
for line in open(path):
    line = line.strip()
    if not line:
        continue
    name, running, default = line.split(":")
    if name == target:
        running = state
    lines.append("%s:%s:%s" % (name, running, default))
open(path, "w").write("".join(l + "\n" for l in lines))
' "$D/machines" "$1" "$2"
}

any_running() {
  grep -q ':true:' "$D/machines" 2>/dev/null
}

case "${1:-}" in
  machine)
    case "${2:-}" in
      list)  render_list; exit 0 ;;
      init)
        # A real init creates the default machine STOPPED and names it
        # itself; the helper must re-probe for that name rather than
        # assuming one.
        echo "podman-machine-default:false:true" >> "$D/machines"
        exit 0
        ;;
      start) set_running "${3:-}" true;  exit 0 ;;
      stop)  set_running "${3:-}" false; exit 0 ;;
    esac
    exit 1
    ;;
  info)
    [ -e "$D/info-broken" ] && exit 1
    any_running || exit 1
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$STUB_BIN/podman"

# new_case <case-name> [<machines-line>...] -- fresh stub state dir.
new_case() {
  local name="$1"; shift
  local d="$WORK/case-$name"
  rm -rf "$d"
  mkdir -p "$d"
  : > "$d/machines"
  : > "$d/log"
  local rec
  for rec in "$@"; do
    echo "$rec" >> "$d/machines"
  done
  echo "$d"
}

# stub_log <case-dir> -- the invocation log as one semicolon-joined line, so
# an assertion can pin the ORDER of the calls, not just their presence.
stub_log() {
  tr '\n' ';' < "$1/log"
}

# ---------------------------------------------------------------------
# 1. The probe: which machine, and is it running.
# ---------------------------------------------------------------------
D="$(new_case probe-empty)"
OUT="$(PATH="$STUB_BIN:$PATH" PODMAN_STUB_DIR="$D" claude_vm_podman_machine_probe)"
assert_eq "probe: no machine on the host yields no output" "" "$OUT"

D="$(new_case probe-stopped 'solo:false:false')"
OUT="$(PATH="$STUB_BIN:$PATH" PODMAN_STUB_DIR="$D" claude_vm_podman_machine_probe)"
assert_eq "probe: sole machine, stopped" "solo	false" "$OUT"

D="$(new_case probe-default 'other:false:false' 'chosen:true:true')"
OUT="$(PATH="$STUB_BIN:$PATH" PODMAN_STUB_DIR="$D" claude_vm_podman_machine_probe)"
assert_eq "probe: prefers the default-flagged machine over the first listed" \
  "chosen	true" "$OUT"

# The name is read from JSON precisely so a default machine's name arrives
# WITHOUT the trailing '*' marker `podman machine list`'s Go template appends
# to it (issue #57): a name carrying that marker resolves to no machine on
# every later start/stop.
D="$(new_case probe-marker 'podman-machine-default:false:true')"
OUT="$(PATH="$STUB_BIN:$PATH" PODMAN_STUB_DIR="$D" claude_vm_podman_machine_probe | cut -f1)"
assert_eq "probe: the default machine's name carries no '*' marker" \
  "podman-machine-default" "$OUT"

# The probe is also the FIRST thing the bring-up runs, so it must survive a
# host with no podman at all rather than erroring: PATH here holds nothing,
# not even the host's own podman.
mkdir -p "$WORK/nobin"
OUT="$(PATH="$WORK/nobin" claude_vm_podman_machine_probe 2>/dev/null)"
assert_eq "probe: podman absent yields no output rather than an error" "" "$OUT"

# ---------------------------------------------------------------------
# 2. The bring-up: one action per state, and nothing more.
# ---------------------------------------------------------------------
# run_ensure <case-dir> -- run the bring-up in a subshell (so the global it
# sets cannot leak between cases) and print `rc:<code> started:<name>`.
run_ensure() {
  local d="$1"
  (
    PATH="$STUB_BIN:$PATH"
    PODMAN_STUB_DIR="$d"
    export PODMAN_STUB_DIR
    claude_vm_ensure_podman_machine >/dev/null 2>&1
    echo "rc:$? started:${CLAUDE_VM_PODMAN_MACHINE_STARTED:-}"
  )
}

D="$(new_case ensure-fresh)"
assert_eq "ensure: fresh host succeeds and records the machine it started" \
  "rc:0 started:podman-machine-default" "$(run_ensure "$D")"
assert_eq "ensure: fresh host inits, re-probes for the name, then starts it" \
  "machine list --format json;machine init;machine list --format json;machine start podman-machine-default;info;" \
  "$(stub_log "$D")"

D="$(new_case ensure-stopped 'solo:false:true')"
assert_eq "ensure: stopped machine is started, and recorded as started here" \
  "rc:0 started:solo" "$(run_ensure "$D")"
assert_eq "ensure: stopped machine is started WITHOUT an init" \
  "machine list --format json;machine start solo;info;" \
  "$(stub_log "$D")"

D="$(new_case ensure-running 'solo:true:true')"
assert_eq "ensure: a running machine is left as found, and recorded as not started" \
  "rc:0 started:" "$(run_ensure "$D")"
assert_eq "ensure: a running machine draws neither an init nor a start" \
  "machine list --format json;info;" \
  "$(stub_log "$D")"

D="$(new_case ensure-broken 'solo:true:true')"
touch "$D/info-broken"
assert_eq "ensure: a running machine podman cannot use is a failure, not a silent pass" \
  "rc:1 started:" "$(run_ensure "$D")"

# podman missing entirely: the build cannot proceed, and the message must
# name podman. PATH is emptied of the stub AND of the host's own podman.
OUT="$(
  PATH="$WORK/nobin" claude_vm_ensure_podman_machine 2>&1
  echo "rc:$?"
)"
assert_eq "ensure: podman absent fails" "rc:1" "$(printf '%s\n' "$OUT" | tail -1)"
case "$OUT" in
  *"'podman' not found on PATH"*)
    PASS=$((PASS + 1)); echo "ok   - ensure: podman absent says so" ;;
  *)
    FAIL=$((FAIL + 1)); echo "FAIL - ensure: podman absent says so"
    echo "        actual: [$OUT]" ;;
esac

# ---------------------------------------------------------------------
# 3. The teardown: undo exactly what this run did.
# ---------------------------------------------------------------------
D="$(new_case stop-started 'solo:true:true')"
OUT="$(
  PATH="$STUB_BIN:$PATH"
  PODMAN_STUB_DIR="$D"
  export PODMAN_STUB_DIR
  CLAUDE_VM_PODMAN_MACHINE_STARTED="solo"
  claude_vm_stop_podman_machine >/dev/null 2>&1
  claude_vm_stop_podman_machine >/dev/null 2>&1
  echo "started:${CLAUDE_VM_PODMAN_MACHINE_STARTED:-}"
)"
assert_eq "stop: the recorded machine is cleared after the stop" "started:" "$OUT"
assert_eq "stop: a second call is a no-op, not a second stop" \
  "machine stop solo;" "$(stub_log "$D")"

D="$(new_case stop-untouched 'solo:true:true')"
OUT="$(
  PATH="$STUB_BIN:$PATH"
  PODMAN_STUB_DIR="$D"
  export PODMAN_STUB_DIR
  CLAUDE_VM_PODMAN_MACHINE_STARTED=""
  claude_vm_stop_podman_machine >/dev/null 2>&1
  echo "rc:$?"
)"
assert_eq "stop: nothing started means nothing stopped" "rc:0" "$OUT"
assert_eq "stop: a machine this run found running is never touched" "" "$(stub_log "$D")"

# ---------------------------------------------------------------------
# 4. The scoping, run against the launcher's own build-or-reuse block.
#
# The block is sliced out of claude-vm.sh and executed with a stub
# build-guest-image.sh, a stub podman, and a scratch $GUEST_IMAGE, once with
# the pinned version already on disk (warm cache) and once without (cold).
# Its trap fires on the harness subshell's exit, which is what makes the
# stop observable in the same log as the init and the start.
# ---------------------------------------------------------------------
BLOCK="$WORK/build-or-reuse.sh"
awk '
  /^HAVE_VERSION=""$/ { grab = 1 }
  grab {
    print
    if (tail && $0 ~ /^fi$/) exit
    if ($0 ~ /--output "\$GUEST_IMAGE"/) tail = 1
  }
' "$LAUNCHER" > "$BLOCK"

if ! grep -q 'claude_vm_ensure_podman_machine' "$BLOCK"; then
  FAIL=$((FAIL + 1))
  echo "FAIL - scoping: build-or-reuse block sliced out of the launcher"
  echo "        the slice did not contain the podman bring-up; the awk markers have moved"
else
  PASS=$((PASS + 1))
  echo "ok   - scoping: build-or-reuse block sliced out of the launcher"

  BUILD_STUB_DIR="$WORK/scriptdir"
  mkdir -p "$BUILD_STUB_DIR"
  cat > "$BUILD_STUB_DIR/build-guest-image.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "build" >> "$BUILD_MARKER"
# --output <path>: leave a file where the real build would, so the block's
# caller sees the same post-build state.
[ "${1:-}" = "--output" ] && [ -n "${2:-}" ] && : > "$2"
exit 0
EOF
  chmod +x "$BUILD_STUB_DIR/build-guest-image.sh"

  # run_block <case-dir> <have-version> -- <have-version> empty means no
  # image on disk. Prints the build marker count.
  run_block() {
    local d="$1" have="$2"
    local img="$d/guest.raw"
    : > "$d/build-marker"
    if [ -n "$have" ]; then
      : > "$img"
      echo "$have" > "$img.version"
    fi
    (
      set -euo pipefail
      PATH="$STUB_BIN:$PATH"
      PODMAN_STUB_DIR="$d"
      export PODMAN_STUB_DIR
      BUILD_MARKER="$d/build-marker"
      export BUILD_MARKER
      # The three the sliced block reads. Exported rather than plain locals
      # only so a static reader can see they are consumed: the consumer is
      # the `. "$BLOCK"` below, which no static reader follows.
      export SCRIPT_DIR="$BUILD_STUB_DIR"
      export GUEST_IMAGE="$img"
      export PINNED_VERSION="v-pinned"
      # shellcheck source=/dev/null
      . "$LIB"
      # shellcheck source=/dev/null
      . "$BLOCK"
    ) >/dev/null 2>&1
    wc -l < "$d/build-marker" | tr -d ' '
  }

  D="$(new_case warm 'solo:false:true')"
  assert_eq "scoping: a warm-cache launch does not build" "0" "$(run_block "$D" v-pinned)"
  assert_eq "scoping: a warm-cache launch never invokes podman at all" \
    "" "$(stub_log "$D")"

  D="$(new_case warm-nomachine)"
  assert_eq "scoping: a warm-cache launch on a host with NO podman machine still does not build" \
    "0" "$(run_block "$D" v-pinned)"
  assert_eq "scoping: a warm-cache launch starts no machine on a host that has none" \
    "" "$(stub_log "$D")"

  D="$(new_case cold-fresh)"
  assert_eq "scoping: a stale-image launch builds" "1" "$(run_block "$D" v-stale)"
  assert_eq "scoping: a fresh host inits, starts, builds, and stops the machine again" \
    "machine list --format json;machine init;machine list --format json;machine start podman-machine-default;info;machine stop podman-machine-default;" \
    "$(stub_log "$D")"

  D="$(new_case cold-stopped 'solo:false:true')"
  assert_eq "scoping: a missing-image launch builds" "1" "$(run_block "$D" "")"
  assert_eq "scoping: a stopped machine is started for the build and stopped after it" \
    "machine list --format json;machine start solo;info;machine stop solo;" \
    "$(stub_log "$D")"

  D="$(new_case cold-running 'solo:true:true')"
  assert_eq "scoping: a build against an already-running machine builds" "1" "$(run_block "$D" "")"
  assert_eq "scoping: a machine found running is left running after the build" \
    "machine list --format json;info;" \
    "$(stub_log "$D")"
fi

echo ""
echo "podman-machine-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
