#!/usr/bin/env bash
#
# machine-name-resolution-test.sh -- regression test for issue #57.
#
# host-acceptance.sh resolves the podman machine name, running-state, and
# default-flag from 'podman machine list --format json'. It must NOT use
# the '{{.Name}}' Go template, because podman renders the DEFAULT
# machine's '{{.Name}}' with a trailing '*' default-marker (e.g.
# 'podman-machine-default*'). Capturing that marker into MACHINE_NAME
# breaks every later 'podman machine start/stop/rm "$MACHINE_NAME"' --
# the marked name resolves to no machine, so a stopped default machine
# can never be started (issue #57).
#
# WHY A FAITHFUL STUB: issues #54 and #56 reviewed host-acceptance.sh
# with throwaway stubbed-podmans that emitted CLEAN machine names with no
# '*' marker, so the stub never reproduced podman's real output and the
# bug slipped through twice. This regression test therefore uses a stub
# that FAITHFULLY reproduces the real shapes:
#
#   - '{{.Name}}' (and any Go template) -> appends the '*' marker to the
#     default machine, exactly as real podman does.
#   - '--format json'                   -> the unmarked 'Name' with
#     structural boolean 'Default'/'Running'.
#
# The stub's '{{.Name}}' output was captured from a real 'podman machine
# list' on a host with a stopped default machine; see issue #57. A test
# whose stub emitted hand-clean names would reproduce the original blind
# spot and is explicitly not relied on here.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/machine-name-resolution-test.sh
#
# Requires: jq. Skips with a clear message if absent (same gating model
# as host-acceptance.sh, which itself requires jq to run).

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available; machine-name-resolution test skipped." >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-name-test.XXXXXX")"
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
# Faithful podman stub.
#
# The stub reads a fixture file ($STUB_FIXTURE, a JSON array) describing
# the machines and answers 'podman machine list' two ways:
#
#   --format json    -> the fixture JSON verbatim (unmarked Name, real
#                       booleans), exactly as real podman emits.
#   --format '<tmpl>' -> a tab-joined Name/Running/Default rendering that
#                       APPENDS the '*' default-marker to the default
#                       machine's Name -- reproducing the real-podman
#                       behavior that issue #57 is about. (We do not
#                       interpret the template literally; we only need it
#                       to faithfully carry the marker the way the buggy
#                       code consumed it.)
# ---------------------------------------------------------------------
STUB="$WORK/podman"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Faithful 'podman' stub for the #57 regression test. Only implements the
# 'machine list' surface the resolution probes use.
set -u
fixture="$STUB_FIXTURE"
if [ "${1:-}" = "machine" ] && [ "${2:-}" = "list" ]; then
  shift 2
  fmt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) fmt="$2"; shift 2 ;;
      --format=*) fmt="${1#--format=}"; shift ;;
      *) shift ;;
    esac
  done
  if [ "$fmt" = "json" ]; then
    cat "$fixture"
  else
    # Any Go template: emit "<Name><marker>\t<Running>\t<Default>" per
    # machine, appending '*' to the default machine's Name exactly as
    # real podman does for a bare {{.Name}} (issue #57).
    jq -r '.[] | (if .Default then (.Name + "*") else .Name end)
           + "\t" + (.Running|tostring) + "\t" + (.Default|tostring)' "$fixture"
  fi
  exit 0
fi
echo "stub-podman: unsupported invocation: $*" >&2
exit 1
STUB_EOF
chmod +x "$STUB"

# resolve_from_stub <fixture-json-file>
# Runs the SAME resolution pipeline host-acceptance.sh uses against the
# stub, and echoes "<name>\t<running>" (empty when no machine).
resolve_from_stub() {
  local fixture="$1"
  STUB_FIXTURE="$fixture" PATH="$WORK:$PATH" bash -c '
    machine_probe="$(podman machine list --format json 2>/dev/null \
      | jq -r "(map(select(.Default==true)) + .)[0]
               | select(. != null)
               | \"\(.Name)\t\(.Running)\t\(.Default)\"" 2>/dev/null)"
    name="$(printf "%s" "$machine_probe" | cut -f1)"
    running="$(printf "%s" "$machine_probe" | cut -f2)"
    printf "%s\t%s" "$name" "$running"
  '
}

# Same pipeline, but the OLD '{{.Name}}'-template form, used ONLY to
# prove the stub genuinely reproduces the bug (the marker leaks through).
resolve_old_template() {
  local fixture="$1"
  STUB_FIXTURE="$fixture" PATH="$WORK:$PATH" bash -c '
    name="$(podman machine list --format "{{.Name}}\t{{.Running}}\t{{.Default}}" 2>/dev/null \
      | awk -F "\t" "\$3==\"true\"{print}" | cut -f1)"
    printf "%s" "$name"
  '
}

# ---------------------------------------------------------------------
# Fixture 1: a single STOPPED default machine -- the exact #57 scenario.
# ---------------------------------------------------------------------
FIX_STOPPED_DEFAULT="$WORK/stopped-default.json"
cat > "$FIX_STOPPED_DEFAULT" <<'JSON'
[
  { "Name": "podman-machine-default", "Default": true, "Running": false }
]
JSON

# Guard: the stub must genuinely reproduce the bug, or the regression
# test is worthless (the #54/#56 blind spot). The OLD template pipeline
# must yield a marked name.
old_name="$(resolve_old_template "$FIX_STOPPED_DEFAULT")"
assert_eq "stub fidelity: old {{.Name}} pipeline DOES capture the * marker" \
  "podman-machine-default*" "$old_name"

# The FIXED JSON pipeline must yield the UNMARKED name + correct state.
result="$(resolve_from_stub "$FIX_STOPPED_DEFAULT")"
assert_eq "fixed: stopped default resolves to UNMARKED name" \
  "podman-machine-default" "$(printf '%s' "$result" | cut -f1)"
assert_eq "fixed: stopped default resolves Running=false" \
  "false" "$(printf '%s' "$result" | cut -f2)"

# ---------------------------------------------------------------------
# Fixture 2: a RUNNING default machine.
# ---------------------------------------------------------------------
FIX_RUNNING_DEFAULT="$WORK/running-default.json"
cat > "$FIX_RUNNING_DEFAULT" <<'JSON'
[
  { "Name": "podman-machine-default", "Default": true, "Running": true }
]
JSON
result="$(resolve_from_stub "$FIX_RUNNING_DEFAULT")"
assert_eq "fixed: running default resolves to UNMARKED name" \
  "podman-machine-default" "$(printf '%s' "$result" | cut -f1)"
assert_eq "fixed: running default resolves Running=true" \
  "true" "$(printf '%s' "$result" | cut -f2)"

# ---------------------------------------------------------------------
# Fixture 3: multiple machines -- the DEFAULT-flagged one is selected,
# not the first by list order, and its name is unmarked.
# ---------------------------------------------------------------------
FIX_MULTI="$WORK/multi.json"
cat > "$FIX_MULTI" <<'JSON'
[
  { "Name": "other-machine",          "Default": false, "Running": true },
  { "Name": "podman-machine-default", "Default": true,  "Running": false }
]
JSON
result="$(resolve_from_stub "$FIX_MULTI")"
assert_eq "fixed: default-flagged machine is selected over list order" \
  "podman-machine-default" "$(printf '%s' "$result" | cut -f1)"
assert_eq "fixed: selected default's Running state is read structurally" \
  "false" "$(printf '%s' "$result" | cut -f2)"

# ---------------------------------------------------------------------
# Fixture 4: machines exist but NONE is default -> fall back to first.
# ---------------------------------------------------------------------
FIX_NO_DEFAULT="$WORK/no-default.json"
cat > "$FIX_NO_DEFAULT" <<'JSON'
[
  { "Name": "alpha", "Default": false, "Running": false },
  { "Name": "beta",  "Default": false, "Running": true }
]
JSON
result="$(resolve_from_stub "$FIX_NO_DEFAULT")"
assert_eq "fixed: no default -> first machine is the fallback" \
  "alpha" "$(printf '%s' "$result" | cut -f1)"

# ---------------------------------------------------------------------
# Fixture 5: empty machine list -> empty name (no machine found).
# ---------------------------------------------------------------------
FIX_EMPTY="$WORK/empty.json"
printf '[]\n' > "$FIX_EMPTY"
result="$(resolve_from_stub "$FIX_EMPTY")"
assert_eq "fixed: empty machine list yields empty name" \
  "" "$(printf '%s' "$result" | cut -f1)"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "machine-name-resolution-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
