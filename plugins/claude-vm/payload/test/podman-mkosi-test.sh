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
# Bug 4 regression (real second real-build failure): render_apt_source used
# to unconditionally splice a NEW [signed-by=...] block onto the repo line,
# even when the repo string already carried its own [options] block. apt's
# one-line format allows exactly ONE options block after deb/deb-src; two
# blocks produces "Malformed entry ... (URI parse)" because the second
# block lands where the URI belongs. This exact shape (an operator-authored
# [arch=... signed-by=...] block) is the githubcli apt_source that hit the
# real failure.
#
# Drive render_apt_source DIRECTLY (not through the whole provisioner) by
# extracting it from the ACTUAL generated build-in-container.sh captured
# above -- CAPTURE_INNER already has the function fully de-escaped (real $
# and real backticks, exactly as it would execute inside the build
# container), so this exercises the real code path, not a hand-copied
# reimplementation. A stubbed curl intercepts the key fetch (no network) but
# every other line -- the regex matching, the case/[[ validation, the path
# arithmetic, the line composition -- is the actual generated code running
# for real under bash.
# ---------------------------------------------------------------------
RENDER_WORK="$WORK/render-apt-source"
mkdir -p "$RENDER_WORK/bin"

# Stub curl: succeed and write a fixed marker as the "fetched key" content,
# regardless of URL, so no network is needed. Real fetch success/failure
# handling (the -fsSL / -o path, the fatal-on-failure branch) is exercised
# by the whole-provisioner run above; this stub only removes the network
# dependency for the direct-call cases below.
cat > "$RENDER_WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
# curl -fsSL <url> -o <path>
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
[ -n "$out" ] || exit 1
printf 'stub-key-material\n' > "$out"
exit 0
EOF
chmod +x "$RENDER_WORK/bin/curl"

if [ -f "$CAPTURE_INNER" ]; then
  # Extract exactly the render_apt_source() { ... } function body (from its
  # def line to the matching closing brace on its own line) into a standalone
  # sourceable file, so sourcing it does not also run the rest of
  # build-in-container.sh (apt-get, mkosi build, etc.).
  RENDER_FN="$RENDER_WORK/render_apt_source.sh"
  awk '
    /^render_apt_source\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "$CAPTURE_INNER" > "$RENDER_FN"

  if [ -s "$RENDER_FN" ]; then
    # call_render <case-label> <name> <repo> <key_url>
    # Sources the extracted function fresh each call (subshell) and invokes
    # it against a clean staging tree, then prints:
    #   RENDERED:<the .list file's content>
    #   KEYFILE:<path the key was actually written to, relative to the
    #            staging root>|<content>
    call_render() {
      local case_label="$1" c_name="$2" c_repo="$3" c_key_url="$4"
      local stage="$RENDER_WORK/stage-$case_label"
      rm -rf "$stage"
      mkdir -p "$stage/sandbox/etc/apt/keyrings" "$stage/sandbox/etc/apt/sources.list.d"
      (
        PATH="$RENDER_WORK/bin:$PATH"
        # shellcheck source=/dev/null
        source "$RENDER_FN"
        render_apt_source "$c_name" "$c_repo" "$c_key_url" \
          "$stage/sandbox/etc/apt/keyrings" "$stage/sandbox/etc/apt/sources.list.d" \
          "/etc/apt/keyrings"
      )
      local rc=$?
      echo "EXIT:$rc"
      local list_file="$stage/sandbox/etc/apt/sources.list.d/${c_name}.list"
      if [ -f "$list_file" ]; then
        echo "RENDERED:$(cat "$list_file")"
      else
        echo "RENDERED:<no .list file written>"
      fi
      # Report every key file actually written under the stage, relative to
      # stage/, so a case-3 write to a NON-default path is visible. Not
      # scoped to *.asc: a repo-authored non-default signed-by= path may use
      # any extension (e.g. the .gpg case below), so match any regular file
      # under sandbox/.
      find "$stage/sandbox" -type f 2>/dev/null | while read -r f; do
        echo "KEYFILE:${f#"$stage"/}"
      done
    }

    # --- Case: bare repo line, no [options] block at all. ---
    OUT="$(call_render bare githubcli-bare 'deb https://cli.github.com/packages stable main' 'https://cli.github.com/packages/key.gpg')"
    assert_eq "bare line: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "bare line: renders exactly one [signed-by=] block at the default runtime path" \
      "deb [signed-by=/etc/apt/keyrings/githubcli-bare.asc] https://cli.github.com/packages stable main" \
      "$RENDERED_LINE"
    assert_eq "bare line: exactly one '[' in rendered output" \
      "1" "$(printf '%s' "$RENDERED_LINE" | grep -o '\[' | wc -l | tr -d ' ')"
    assert_contains "bare line: key written to default staging path" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox/etc/apt/keyrings/githubcli-bare.asc"

    # --- Case: [options] block present, WITHOUT signed-by=. ---
    OUT="$(call_render optnosb githubcli-opt 'deb [arch=arm64] https://cli.github.com/packages stable main' 'https://cli.github.com/packages/key.gpg')"
    assert_eq "options-no-signed-by: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "options-no-signed-by: merges signed-by INTO the existing block, arch preserved" \
      "deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli-opt.asc] https://cli.github.com/packages stable main" \
      "$RENDERED_LINE"
    assert_eq "options-no-signed-by: exactly one '[' in rendered output (single block)" \
      "1" "$(printf '%s' "$RENDERED_LINE" | grep -o '\[' | wc -l | tr -d ' ')"

    # --- Case: [options] block present WITH an existing signed-by= at a
    # NON-default path P. The repo line must win verbatim, and the key must
    # land at P's staging equivalent, not the default <name>.asc location. ---
    NONDEFAULT_P="/usr/share/keyrings/custom-githubcli.gpg"
    REPO_WITH_P="deb [arch=arm64 signed-by=${NONDEFAULT_P}] https://cli.github.com/packages stable main"
    OUT="$(call_render nondefault githubcli-nd "$REPO_WITH_P" 'https://cli.github.com/packages/key.gpg')"
    assert_eq "existing signed-by at non-default P: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "existing signed-by at non-default P: line kept byte-for-byte verbatim (P wins)" \
      "$REPO_WITH_P" "$RENDERED_LINE"
    assert_contains "existing signed-by at non-default P: key written to P's staging equivalent" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox${NONDEFAULT_P}"
    assert_not_contains "existing signed-by at non-default P: key NOT written to the default <name>.asc path" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox/etc/apt/keyrings/githubcli-nd.asc"

    # --- Case: the EXACT githubcli line from the real failure report. ---
    REAL_FAILURE_REPO="deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli.asc] https://cli.github.com/packages stable main"
    OUT="$(call_render realfail githubcli "$REAL_FAILURE_REPO" 'https://cli.github.com/packages/githubcli-archive-keyring.gpg')"
    assert_eq "real githubcli failure line: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "real githubcli failure line: rendered verbatim (P == default path here, still wins verbatim)" \
      "$REAL_FAILURE_REPO" "$RENDERED_LINE"
    # Structural apt-shape validation (not just substring matching): exactly
    # one '[...]' group, then a URI starting with http, matching
    # "deb <ONE bracket-group> http...". This is the shape apt's one-line
    # parser requires -- a second bracket group here is exactly what
    # produced "Malformed entry ... (URI parse)" in the real failure.
    assert_eq "real githubcli failure line: exactly one '[' " \
      "1" "$(printf '%s' "$RENDERED_LINE" | grep -o '\[' | wc -l | tr -d ' ')"
    assert_eq "real githubcli failure line: exactly one ']' " \
      "1" "$(printf '%s' "$RENDERED_LINE" | grep -o ']' | wc -l | tr -d ' ')"
    if [[ "$RENDERED_LINE" =~ ^deb[[:space:]]+\[[^]]*\][[:space:]]+https?:// ]]; then
      PASS=$((PASS + 1))
      echo "ok   - real githubcli failure line: matches 'deb <one bracket-group> <http-uri>' shape apt requires"
    else
      FAIL=$((FAIL + 1))
      echo "FAIL - real githubcli failure line: does not match 'deb <one bracket-group> <http-uri>' shape"
      echo "        actual: [$RENDERED_LINE]"
    fi
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - could not extract render_apt_source() body from $CAPTURE_INNER"
  fi
else
  FAIL=$((FAIL + 1))
  echo "FAIL - generated build-in-container.sh not found at $CAPTURE_INNER (cannot run render_apt_source cases)"
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "podman-mkosi-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
