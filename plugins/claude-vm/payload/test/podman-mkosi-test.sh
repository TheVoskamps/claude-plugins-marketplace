#!/usr/bin/env bash
#
# podman-mkosi-test.sh -- regression tests for provisioners/podman-mkosi.sh's
# generated recipe, covering a real end-to-end build failure (issue #105
# review follow-up, PR #161) that 151 pure-function config-test.sh cases did
# not catch, because none of them render or execute the actual generated
# recipe files.
#
# A real 'podman-mkosi build' run with packages.bake: [gh] and a
# cli.github.com apt_source hit three failures:
#
#   1. Host-side 'cp: illegal option -- -' (BSD cp rejecting a GNU long
#      flag) coming from... nowhere in this script's own cp invocations.
#   2. Host-side 'hashed:: command not found', corrupting the generated
#      mkosi.conf's RootPassword= line.
#   3. In-container 'curl: command not found', so render_apt_source's
#      key_url fetch failed before any baked package could be installed.
#
# Root cause of (1) and (2): podman-mkosi.sh writes mkosi.conf via an
# UNQUOTED heredoc (<<CONF, not <<'CONF' -- required so $GUEST_SUITE
# interpolates). Two comment lines inside that heredoc body used
# markdown-style PAIRED BACKTICKS ('`cp --preserve=...,xattr`',
# '`hashed:`') to typeset a command example. Backticks are command
# substitution syntax to the shell regardless of the '#' in front of them
# -- '#' has no special meaning inside a heredoc body. Bash therefore
# executed 'cp --preserve=...,xattr' and 'hashed:' as real host commands
# and spliced their (error) output into mkosi.conf in place of the comment
# text. This is a single class of defect (paired backticks in an unquoted
# heredoc's comment prose), not two unrelated cp/RootPassword bugs.
#
# Root cause of (3): the in-container apt-get install list (for the mkosi
# v26 toolchain) never included curl/ca-certificates, even though
# render_apt_source (added by issue #105) runs 'curl -fsSL "$key_url"'
# inside that same container to fetch each packages.apt_sources key.
#
# These tests exercise the REAL generated artifacts podman-mkosi.sh
# produces on the actual host code path (stubbing only 'podman' itself, at
# the point it would hand off to the container) -- not just the pure
# config.sh layering functions. They render mkosi.conf and
# build-in-container.sh exactly as a real build would and assert on their
# literal content. They do not run an actual mkosi build (no container, no
# network) -- that requires a real podman machine and is the residual gap
# noted in the PR.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/podman-mkosi-test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER="$TEST_DIR/../provisioners/podman-mkosi.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-mkosi-test.XXXXXX")"
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

# assert_contains <label> <haystack-file> <needle>
assert_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "ok   - $label"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $label"
    echo "        expected to find in $file: [$needle]"
  fi
}

# assert_not_contains <label> <haystack-file> <needle>
assert_not_contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "FAIL - $label"
    echo "        did not expect to find in $file: [$needle]"
  else
    PASS=$((PASS + 1))
    echo "ok   - $label"
  fi
}

# ---------------------------------------------------------------------
# Stub podman: 'info' succeeds (so the preflight passes); 'run' captures
# the staged recipe dir and the bind-mounted build-in-container.sh, then
# exits nonzero WITHOUT actually running a container. This lets the real
# podman-mkosi.sh host-side logic run to completion (recipe staged, both
# heredocs rendered) without needing a real podman machine.
# ---------------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
CAPTURE_RECIPE="$WORK/captured-recipe"
CAPTURE_INNER="$WORK/captured-build-in-container.sh"

cat > "$STUB_BIN/podman" <<EOF
#!/usr/bin/env bash
case "\$1" in
  info) exit 0 ;;
  run)
    for a in "\$@"; do
      case "\$a" in
        *:/work/recipe)
          rm -rf "$CAPTURE_RECIPE"
          cp -R "\${a%%:/work/recipe}" "$CAPTURE_RECIPE"
          ;;
        *build-in-container.sh:/work/build-in-container.sh:ro)
          cp "\${a%%:/work/build-in-container.sh:ro}" "$CAPTURE_INNER"
          ;;
      esac
    done
    exit 42
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB_BIN/podman"

BOOT_LAUNCHER="$WORK/fake-boot-launcher.sh"
printf '#!/usr/bin/env bash\n' > "$BOOT_LAUNCHER"
chmod +x "$BOOT_LAUNCHER"
OUT_IMAGE="$WORK/out.raw"

run_provisioner() {
  local bake_config="$1"
  PATH="$STUB_BIN:$PATH" \
  CLAUDE_VM_BAKE_CONFIG="$bake_config" \
  bash "$PROVISIONER" "$BOOT_LAUNCHER" "$OUT_IMAGE" >"$WORK/stdout.log" 2>"$WORK/stderr.log"
}

BAKE_CONFIG='{"bake":["gh"],"apt_sources":[{"name":"githubcli","repo":"deb [arch=amd64] https://cli.github.com/packages stable main","key_url":"https://cli.github.com/packages/githubcli-archive-keyring.gpg"}]}'

run_provisioner "$BAKE_CONFIG"
RUN_EXIT=$?

# ---------------------------------------------------------------------
# Sanity: the stub's deliberate exit 42 (at the container-handoff point)
# must be what stopped the script -- otherwise the run failed earlier for
# an unrelated reason and every assertion below would be testing a
# not-actually-exercised path.
# ---------------------------------------------------------------------
assert_eq "provisioner reaches container handoff (stub exit 42)" "42" "$RUN_EXIT"

# ---------------------------------------------------------------------
# Bug 1 + Bug 2 regression: no stray command execution from the mkosi.conf
# heredoc's comment prose. Both observed host-side failures
# ('cp: illegal option', 'hashed:: command not found') would show up as
# these exact strings on stderr if the backtick-command-substitution
# defect reappears.
# ---------------------------------------------------------------------
assert_not_contains "no 'illegal option' error on stderr (Bug 1)" \
  "$WORK/stderr.log" "illegal option"
assert_not_contains "no 'hashed:: command not found' on stderr (Bug 2)" \
  "$WORK/stderr.log" "hashed:: command not found"
assert_not_contains "no 'command not found' at all on stderr" \
  "$WORK/stderr.log" "command not found"

# ---------------------------------------------------------------------
# Bug 2: the generated mkosi.conf must contain the LITERAL RootPassword
# line, not a shell-executed/corrupted substitute.
# ---------------------------------------------------------------------
MKOSI_CONF="$CAPTURE_RECIPE/mkosi.conf"
if [ -f "$MKOSI_CONF" ]; then
  assert_contains "generated mkosi.conf has literal RootPassword=hashed:" \
    "$MKOSI_CONF" "RootPassword=hashed:"
  assert_eq "RootPassword line appears exactly once" \
    "1" "$(grep -c '^RootPassword=hashed:$' "$MKOSI_CONF")"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - generated mkosi.conf not found at $MKOSI_CONF"
fi

# ---------------------------------------------------------------------
# Bug 3: the generated build-in-container.sh must install curl (and
# ca-certificates for TLS trust) in the SAME apt-get install step that
# provisions the rest of the build-container toolchain, and that install
# must appear textually BEFORE render_apt_source's curl invocation.
# ---------------------------------------------------------------------
if [ -f "$CAPTURE_INNER" ]; then
  assert_contains "generated build-in-container.sh installs curl" \
    "$CAPTURE_INNER" "curl"
  assert_contains "generated build-in-container.sh installs ca-certificates" \
    "$CAPTURE_INNER" "ca-certificates"

  INSTALL_LINE="$(grep -n '^apt-get install' "$CAPTURE_INNER" | head -1 | cut -d: -f1)"
  CURL_FETCH_LINE="$(grep -n 'curl -fsSL' "$CAPTURE_INNER" | head -1 | cut -d: -f1)"
  if [ -n "$INSTALL_LINE" ] && [ -n "$CURL_FETCH_LINE" ]; then
    if [ "$INSTALL_LINE" -lt "$CURL_FETCH_LINE" ]; then
      PASS=$((PASS + 1))
      echo "ok   - apt-get install (line $INSTALL_LINE) precedes curl -fsSL fetch (line $CURL_FETCH_LINE)"
    else
      FAIL=$((FAIL + 1))
      echo "FAIL - apt-get install (line $INSTALL_LINE) does not precede curl -fsSL fetch (line $CURL_FETCH_LINE)"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - could not locate apt-get install and/or curl -fsSL lines in generated script"
  fi

  bash -n "$CAPTURE_INNER"
  assert_eq "generated build-in-container.sh is syntactically valid bash" "0" "$?"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - generated build-in-container.sh not found at $CAPTURE_INNER"
fi

# ---------------------------------------------------------------------
# No-bake config: the same heredoc-rendering path must stay clean even
# when there is nothing to bake (the common/default case).
# ---------------------------------------------------------------------
run_provisioner ""
NOBAKE_EXIT=$?
assert_eq "no-bake config also reaches container handoff (stub exit 42)" "42" "$NOBAKE_EXIT"
assert_not_contains "no-bake config: no 'command not found' on stderr" \
  "$WORK/stderr.log" "command not found"
if [ -f "$CAPTURE_RECIPE/mkosi.conf" ]; then
  assert_contains "no-bake config: mkosi.conf still has literal RootPassword=hashed:" \
    "$CAPTURE_RECIPE/mkosi.conf" "RootPassword=hashed:"
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "podman-mkosi-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
