#!/usr/bin/env bash
#
# claude-home-test.sh -- drive plugins/cc-tools/bin/claude-home under the
# bash 3.2 macOS ships: what it prints and what it refuses.
#
# Usage: claude-home-test.sh    (exit 0 when every case passes)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$TEST_DIR/../bin/claude-home"
FAILURES=0

# check <label> <expected> <env-argument>… -- passes when claude-home, run
# through env with the arguments, exits and prints, stdout and stderr
# together, as <expected>, `<status>:<output>`.
check() {
  local label=$1 expected=$2 out actual
  shift 2
  out=$(env "$@" 2>&1)
  actual="$?:$out"
  if [ "$actual" = "$expected" ]; then
    echo "PASS  $label"
  else
    echo "FAIL  $label"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

NEITHER="1:claude-home: neither CLAUDE_CONFIG_DIR nor HOME is set"

check "CLAUDE_CONFIG_DIR set: printed" "0:/a b/c" CLAUDE_CONFIG_DIR="/a b/c" HOME=/h /bin/bash "$CLAUDE_HOME"
check "CLAUDE_CONFIG_DIR unset: ~/.claude" "0:/h/.claude" -u CLAUDE_CONFIG_DIR HOME=/h /bin/bash "$CLAUDE_HOME"
check "CLAUDE_CONFIG_DIR empty: ~/.claude" "0:/h/.claude" CLAUDE_CONFIG_DIR= HOME=/h /bin/bash "$CLAUDE_HOME"
check "HOME unset, CLAUDE_CONFIG_DIR set: printed" "0:/a" -u HOME CLAUDE_CONFIG_DIR=/a /bin/bash "$CLAUDE_HOME"
check "relative CLAUDE_CONFIG_DIR: made absolute" "0:$PWD/rel" CLAUDE_CONFIG_DIR=rel HOME=/h /bin/bash "$CLAUDE_HOME"
check "both unset: refused" "$NEITHER" -u CLAUDE_CONFIG_DIR -u HOME /bin/bash "$CLAUDE_HOME"
check "both empty: refused" "$NEITHER" CLAUDE_CONFIG_DIR= HOME= /bin/bash "$CLAUDE_HOME"
check "an argument: refused" "1:claude-home: takes no arguments" HOME=/h /bin/bash "$CLAUDE_HOME" x
check "executable by itself" "0:/a" CLAUDE_CONFIG_DIR=/a "$CLAUDE_HOME"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
