#!/usr/bin/env bash
#
# git-issue-branch-test.sh -- drive plugins/git-tools/bin/git-issue-branch,
# under the bash 3.2 macOS ships, with stub `issue-branch-prefix` and
# `issue-view` executables first on PATH.
#
# Reaches no network and reads no config.
#
# Usage: git-issue-branch-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../bin/git-issue-branch"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/git-issue-branch-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAILURES=0

check() {
  if [ "$1" = "$2" ]; then
    echo "PASS  $3"
  else
    echo "FAIL  $3"
    echo "      expected: $2"
    echo "      actual:   $1"
    FAILURES=$((FAILURES + 1))
  fi
}

check_contains() {
  case "$1" in
    *"$2"*) echo "PASS  $3" ;;
    *)
      echo "FAIL  $3"
      echo "      expected to contain: $2"
      echo "      actual:              $1"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

STUBS="$SANDBOX/bin"
CALLS="$SANDBOX/calls"
mkdir -p "$STUBS"

# The prefix stub prints what STUB_MODE and STUB_VALUE ask for, with
# STUB_PAD after each value, or fails when STUB_PREFIX_FAIL is set.
cat >"$STUBS/issue-branch-prefix" <<'STUB'
#!/usr/bin/env bash
echo "issue-branch-prefix" >>"$CALLS"
if [ -n "${STUB_PREFIX_FAIL:-}" ]; then
  echo "stub: branch-prefix-initials is unset" >&2
  exit 4
fi
case "$STUB_MODE" in
  none) printf 'mode: none%s\nprefix:%s\n' "$STUB_PAD" "$STUB_PAD" ;;
  *) printf 'mode: %s%s\nprefix: %s/%s\n' "$STUB_MODE" "$STUB_PAD" "$STUB_VALUE" "$STUB_PAD" ;;
esac
STUB

# The view stub prints the issue's first line with the state $STATES
# gives it, or fails as not found when $STATES has no line for it.
cat >"$STUBS/issue-view" <<'STUB'
#!/usr/bin/env bash
echo "issue-view $1" >>"$CALLS"
state=$(awk -v n="$1" '$1 == n { print $2 }' "$STATES")
if [ -z "$state" ]; then
  echo "stub: issue #$1 not found" >&2
  exit 1
fi
printf '#%s A (title) with parens    (%s)\nhttps://example.test/%s\n' "$1" "$state" "$1"
STUB
chmod +x "$STUBS/issue-branch-prefix" "$STUBS/issue-view"

STATES="$SANDBOX/states"
printf '%s\n' "5 OPEN" "6 OPEN" "7 OPEN" "8 CLOSED" >"$STATES"
export CALLS STATES STUB_MODE=none STUB_VALUE='' STUB_PAD='' STUB_PREFIX_FAIL=''

# run <args...> -- run the script from an empty directory; leaves OUT,
# ERR, RC, and the stub calls it made in CALLED.
run() {
  : >"$CALLS"
  OUT=$(cd "$SANDBOX" && PATH="$STUBS:$PATH" /bin/bash "$SCRIPT" "$@" 2>"$SANDBOX/stderr")
  RC=$?
  ERR=$(cat "$SANDBOX/stderr")
  CALLED=$(cat "$CALLS")
}

check "$([ -x "$SCRIPT" ] && echo yes)" "yes" "git-issue-branch is executable"

# --- round trip under each prefix mode -------------------------------------
for mode in none initials name; do
  STUB_MODE=$mode
  case "$mode" in
    none) STUB_VALUE='' prefix='' ;;
    initials) STUB_VALUE=ev prefix=ev/ ;;
    name) STUB_VALUE=edwin prefix=edwin/ ;;
  esac
  for pad in "" "   "; do
    STUB_PAD=$pad
    run encode 5 --slug fix-thing
    check "$RC:$OUT" "0:${prefix}issue-5-fix-thing" "$mode, pad '${pad}': k=1 encodes"
    run encode 7 5 6 --slug batch-sweep
    check "$RC:$OUT" "0:${prefix}issue-7-5-6-batch-sweep" "$mode, pad '${pad}': k=3 encodes in the order given"
  done
  STUB_PAD=
  run encode 5 --slug fix-thing
  run decode "$OUT"
  check "$RC:$OUT" "0:outcome: convention
issues: 5
slug: fix-thing" "$mode: k=1 decodes to what was encoded"
  run encode 7 5 6 --slug batch-sweep
  run decode "$OUT"
  check "$RC:$OUT" "0:outcome: convention
issues: 7 5 6
slug: batch-sweep" "$mode: k=3 decodes to what was encoded, in order"
done
STUB_MODE=none STUB_VALUE=

# --- issue arguments --------------------------------------------------------
run encode 5 '#6' --slug two-forms
plain=$OUT
run encode '#5' 6 --slug two-forms
check "$RC:$OUT" "0:$plain" "N and #N encode the same name"
check "$plain" "issue-5-6-two-forms" "the name carries bare numbers"

for token in 5,6 'owner/repo#5' 'repo#5' 'other.host/owner/repo#5' https://github.com/o/r/issues/5 0 007 x -; do
  run encode "$token" --slug some-slug
  check "$RC:$OUT" "3:" "encode \`$token\`: exit 3, nothing on stdout"
  check_contains "$ERR" "\`$token\` is not an issue in this repository" "encode \`$token\`: stderr names the token"
done
run encode 5, 6 --slug some-slug
check "$RC" "3" "encode: a trailing comma is rejected"
check_contains "$ERR" "\`5,\`" "encode: the trailing-comma token is named"

# --- validation errors ------------------------------------------------------
run encode 5
check "$RC:$OUT" "4:" "one issue, no slug: exit 4"
check "$ERR" "git-issue-branch: issue 5 has no slug: pass one with \`--slug <slug>\`." "one issue, no slug: the fixed message"
check "$CALLED" "" "one issue, no slug: no stub was run"

run encode 5 6
check "$RC" "5" "two issues, no slug: exit 5"
check_contains "$ERR" "issues 5 6 have no slug" "two issues, no slug: stderr names the issues"

run encode 5 --slug 2-space-indent
check "$RC" "6" "leading-digit slug: exit 6"
check_contains "$ERR" "\`2-space-indent\` begins with a digit" "leading-digit slug: stderr names it"

for slug in Fix-thing fix_thing fix--thing fix-thing- -fix '' "fix
thing" fixé; do
  run encode 5 --slug "$slug"
  check "$RC" "7" "slug \`$slug\` not kebab-case: exit 7"
  check_contains "$ERR" "slug \`$slug\` is not kebab-case" "slug \`$slug\` not kebab-case: stderr names it"
done
run encode 5 --slug a1-b2-c3
check "$RC:$OUT" "0:issue-5-a1-b2-c3" "a slug with digits after the first letter is kebab-case"

long=$(printf 'a%.0s' $(seq 1 92))
run encode 5 --slug "$long"
check "$RC:$OUT" "0:issue-5-$long" "a 100-character name is accepted"
STUB_MODE=initials STUB_VALUE=ev
run encode 5 --slug "$long"
check "$RC:$OUT" "10:" "a 103-character name with its prefix: exit 10"
check_contains "$ERR" "\`ev/issue-5-$long\` is 103 characters" "too long: stderr names the name and its length"
STUB_MODE=none STUB_VALUE=

run encode 5 9 --slug some-slug
check "$RC:$OUT" "11:" "missing issue: exit 11, nothing on stdout"
check_contains "$ERR" "stub: issue #9 not found" "missing issue: issue-view's stderr is relayed"
check_contains "$ERR" "issue 9 was not found" "missing issue: stderr names the issue"

run encode 5 8 --slug some-slug
check "$RC:$OUT" "12:" "closed issue: exit 12, nothing on stdout"
check_contains "$ERR" "issue 8 is CLOSED, not OPEN" "closed issue: stderr names the issue and its state"

STUB_PREFIX_FAIL=1
run encode 5 --slug some-slug
check "$RC:$OUT" "8:" "issue-branch-prefix fails: exit 8, nothing on stdout"
check_contains "$ERR" "stub: branch-prefix-initials is unset" "issue-branch-prefix fails: its stderr is relayed"
run decode issue-5-some-slug 5
check "$RC" "0" "decode succeeds while issue-branch-prefix fails"
check "$CALLED" "" "decode runs neither issue-branch-prefix nor issue-view"
STUB_PREFIX_FAIL=

run encode 5 6 --slug some-slug
check "$CALLED" "issue-branch-prefix
issue-view 5
issue-view 6" "encode runs issue-branch-prefix once and issue-view per issue"

# --- usage errors -----------------------------------------------------------
for args in "" "bogus" "encode" "encode --slug" "encode 5 --slug a --slug b" "encode 5 --bogus" "decode"; do
  read -r -a argv <<<"$args"
  run ${argv[@]+"${argv[@]}"}
  check "$RC:$OUT:$CALLED" "2::" "usage: \`$args\` exits 2, prints nothing, runs nothing"
done
run decode issue-5-x 5,
check "$RC" "2" "decode: a comma-separated claim is a usage error"
check_contains "$ERR" "claimed issue \`5,\`" "decode: the claim token is named"
run decode issue-5-x 'owner/repo#5'
check "$RC" "2" "decode: a cross-repository claim is a usage error"
run decode issue-5-x https://github.com/o/r/issues/5
check "$RC" "2" "decode: an issue-URL claim is a usage error"

# --- decode outcomes --------------------------------------------------------
NOT="outcome: not-a-convention-branch
issues:
slug:"
for name in dependabot/npm_and_yarn/undici-5.28.4 a/b/issue-5-x issue-5 issue-5-6 issue-5- issue-5--x \
  /issue-5-x feature-x issue-x main; do
  run decode "$name"
  check "$RC:$OUT" "0:$NOT" "decode \`$name\`: not a convention branch"
done
run decode someone-else/issue-5-6-a-slug
check "$OUT" "outcome: convention
issues: 5 6
slug: a-slug" "decode: a segment other than the configured value still decodes"
run decode issue-5-6-2-space-indent
check "$OUT" "outcome: convention
issues: 5 6 2
slug: space-indent" "decode: a leading-digit slug merges into the issue set"

# --- reconciliation ---------------------------------------------------------
run decode issue-206-196-201-gate-sweep 206 '#196' 310
check "$RC:$OUT" "0:outcome: convention
issues: 206 196 201
slug: gate-sweep
resolved: 206 196
claimed-outside: 310
unclaimed: 201" "overlap: the intersection, with both side lists"

run decode issue-206-196-201-gate-sweep '#196' 206
plain=$OUT
run decode issue-206-196-201-gate-sweep 196 '#206'
check "$OUT" "$plain" "claims as N and #N resolve alike"

run decode issue-206-a-slug 310
check "$OUT" "outcome: convention
issues: 206
slug: a-slug
resolved: 206
claimed-outside: 310
unclaimed:" "no overlap, one-member branch: the branch set stands in"

run decode issue-206-196-gate-sweep 310 311
check "$RC:$OUT" "0:outcome: convention
issues: 206 196
slug: gate-sweep
resolved: (none)
claimed-outside: 310 311
unclaimed: 206 196" "no overlap, several members: no resolved set"

run decode dependabot/npm_and_yarn/undici-5.28.4 310 '#311'
check "$RC:$OUT" "0:$NOT
resolved: 310 311
claimed-outside:
unclaimed:" "not a convention branch: the claim stands, both lists empty"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
