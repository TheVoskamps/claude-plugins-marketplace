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
  local bake_config="$1" headroom_mb="${2:-}"
  PATH="$STUB_BIN:$PATH" \
  CLAUDE_VM_BAKE_CONFIG="$bake_config" \
  CLAUDE_VM_ROOT_HEADROOM_MB="$headroom_mb" \
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
  # The two guest-side boot phases each need a binary that mkosi would
  # otherwise never put in the rootfs (it installs baked packages from OUTSIDE
  # the image with the build container's own tooling): boot_apt_phase needs
  # apt-get, and boot_plugin_phase needs SYSTEM GIT, which the claude CLI
  # shells out to for every git-url marketplace operation. Both are baked
  # UNCONDITIONALLY, so assert them on this default (nothing configured) run:
  # a git-less guest makes claude.plugins.update_at_boot permanently inert.
  assert_eq "guest Packages= bakes apt unconditionally (boot_apt_phase)" \
    "1" "$(grep -c '^ *apt$' "$MKOSI_CONF")"
  assert_eq "guest Packages= bakes git unconditionally (boot_plugin_phase)" \
    "1" "$(grep -c '^ *git$' "$MKOSI_CONF")"
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

# Stub curl: succeed and write "fetched key" content that depends on the URL,
# so no network is needed AND both content shapes (issue #106 review, PR #174
# round 6) are exercisable:
#   - a URL containing "binary" writes RAW/BINARY OpenPGP-shaped bytes (does
#     NOT start with "-----BEGIN PGP") -- the shape GitHub's real
#     githubcli-archive-keyring.gpg is served as, verified in a live guest to
#     make apt >= 2.x silently load an EMPTY keyring when saved under a
#     hard-coded ".asc" name (apt infers armored-vs-binary from the file
#     EXTENSION, not content).
#   - every other URL writes ASCII-ARMORED content starting with the literal
#     "-----BEGIN PGP" header, matching a real armored keyring export.
# Real fetch success/failure handling (the -fsSL / -o path, the
# fatal-on-failure branch) is exercised by the whole-provisioner run above;
# this stub only removes the network dependency for the direct-call cases
# below.
cat > "$RENDER_WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
# curl -fsSL <url> -o <path>
out=""
prev=""
url=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  case "$a" in
    -*) : ;;
    *) [ -n "$url" ] || url="$a" ;;
  esac
  prev="$a"
done
[ -n "$out" ] || exit 1
case "$url" in
  *binary*)
    # Raw/binary OpenPGP-shaped bytes: leading 0x99 0x02 (an OpenPGP packet
    # header), never the "-----BEGIN PGP" armor header.
    printf '\x99\x02stub-binary-key-material\n' > "$out"
    ;;
  *)
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nstub-armored-key-material\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$out"
    ;;
esac
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

    # -----------------------------------------------------------------
    # Content-sniffing regression (issue #106 review finding, PR #174 round
    # 6, real-guest failure): render_apt_source used to hard-name the
    # fetched key "<name>.asc" regardless of its actual content. GitHub
    # serves githubcli-archive-keyring.gpg as RAW/BINARY OpenPGP (not
    # ASCII-armored); apt >= 2.x infers armored-vs-binary from the FILE
    # EXTENSION, not content, so a binary keyring saved under a ".asc" name
    # silently loads as an EMPTY keyring -- verified in a live bookworm/apt
    # 2.6.1 guest as NO_PUBKEY / "repository is not signed" on every boot,
    # even though the identical bytes verify fine under gpgv (which DOES
    # sniff content). The fix sniffs the fetched bytes for the literal
    # "-----BEGIN PGP" armor header and writes/references ".asc" only when
    # present; anything else (raw binary OpenPGP) is written/referenced as
    # ".gpg" instead. The curl stub above keys off "binary" in the URL to
    # produce non-armored bytes for exactly this case.
    # -----------------------------------------------------------------

    # --- Case: bare repo line, fetched key is BINARY (not armored) -- must
    # be written and referenced as .gpg, not the default .asc. ---
    OUT="$(call_render bare-binary githubcli-bin 'deb https://cli.github.com/packages stable main' 'https://cli.github.com/packages/binary-key.gpg')"
    assert_eq "bare line, binary key: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "bare line, binary key: renders signed-by= referencing .gpg, not .asc" \
      "deb [signed-by=/etc/apt/keyrings/githubcli-bin.gpg] https://cli.github.com/packages stable main" \
      "$RENDERED_LINE"
    assert_contains "bare line, binary key: key written to the .gpg staging path" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox/etc/apt/keyrings/githubcli-bin.gpg"
    assert_not_contains "bare line, binary key: no stray .asc file left behind" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox/etc/apt/keyrings/githubcli-bin.asc"

    # --- Case: bare repo line, fetched key IS armored -- must stay .asc
    # (content-driven, not a blanket switch to .gpg). ---
    OUT="$(call_render bare-armored githubcli-arm 'deb https://cli.github.com/packages stable main' 'https://cli.github.com/packages/armored-key.asc')"
    assert_eq "bare line, armored key: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "bare line, armored key: renders signed-by= referencing .asc" \
      "deb [signed-by=/etc/apt/keyrings/githubcli-arm.asc] https://cli.github.com/packages stable main" \
      "$RENDERED_LINE"
    assert_contains "bare line, armored key: key written to the .asc staging path" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox/etc/apt/keyrings/githubcli-arm.asc"

    # --- Case: [options] block present WITHOUT signed-by=, fetched key is
    # BINARY -- the merged signed-by= must reference .gpg. ---
    OUT="$(call_render optnosb-binary githubcli-optbin 'deb [arch=arm64] https://cli.github.com/packages stable main' 'https://cli.github.com/packages/binary-key.gpg')"
    assert_eq "options-no-signed-by, binary key: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "options-no-signed-by, binary key: merges signed-by=.gpg INTO the existing block" \
      "deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli-optbin.gpg] https://cli.github.com/packages stable main" \
      "$RENDERED_LINE"
    assert_contains "options-no-signed-by, binary key: key written to the .gpg staging path" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox/etc/apt/keyrings/githubcli-optbin.gpg"

    # --- Case: the REAL githubcli failure line, but WITHOUT a pinned
    # signed-by= (so the default-naming/sniff path is exercised end-to-end
    # with the real GitHub binary-keyring key_url shape). ---
    OUT="$(call_render realfail-nopin githubcli-real 'deb [arch=arm64] https://cli.github.com/packages stable main' 'https://cli.github.com/packages/binary-key.gpg')"
    assert_eq "real githubcli shape, no pin, binary key: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "real githubcli shape, no pin, binary key: signed-by references .gpg" \
      "deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli-real.gpg] https://cli.github.com/packages stable main" \
      "$RENDERED_LINE"

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

    # --- Case: the EXACT githubcli line from the real failure report, with
    # a PINNED signed-by=...githubcli.asc AND a binary key_url. The pinned
    # path is EXEMPT from the content-sniff rename (round 6 fix): the repo
    # line's declared path wins verbatim regardless of what the fetched
    # bytes look like, because renaming would desync the emitted signed-by=
    # from the file actually written. (This means an operator who pins a
    # ".asc" path for a key that is actually binary still gets a broken
    # apt config -- that is the operator's own declared path, not this
    # function's default to second-guess; the sniff-rename applies only to
    # the DEFAULT <name>.<ext> naming this function itself chooses.) ---
    REAL_FAILURE_REPO="deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli.asc] https://cli.github.com/packages stable main"
    OUT="$(call_render realfail githubcli "$REAL_FAILURE_REPO" 'https://cli.github.com/packages/binary-key.gpg')"
    assert_eq "real githubcli failure line: exit 0" "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "real githubcli failure line: rendered verbatim (P == default path here, still wins verbatim)" \
      "$REAL_FAILURE_REPO" "$RENDERED_LINE"
    assert_contains "real githubcli failure line: binary bytes still land at the PINNED .asc path (not renamed)" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox/etc/apt/keyrings/githubcli.asc"
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
    # -----------------------------------------------------------------
    # Security regression (review round 3, High): case 3 (repo line already
    # carries its own signed-by=P) used to accept ANY absolute,
    # charset-safe, '..'-free P and write the fetched key there verbatim.
    # apt_sources is unioned in from the per-repo (UNTRUSTED)
    # .claude-vm/config-bake.yml, so a malicious config could pair
    # signed-by=/etc/cron.d/x with an attacker-served key_url to get
    # attacker-controlled bytes written to an arbitrary path in the guest
    # image staging tree, which then boots as root. render_apt_source must
    # now accept P ONLY when it is directly under /etc/apt/keyrings or
    # /usr/share/keyrings (no further subdirectories), and reject (exit
    # nonzero, write nothing) everything else.
    # -----------------------------------------------------------------

    # --- (a) case-3 P under /etc/apt/keyrings -- still works verbatim. ---
    P_ETC="/etc/apt/keyrings/foo.asc"
    REPO_P_ETC="deb [arch=amd64 signed-by=${P_ETC}] https://example.test/repo stable main"
    OUT="$(call_render seckeep-etc secure-etc "$REPO_P_ETC" 'https://example.test/repo/key.asc')"
    assert_eq "keyrings-dir constraint: /etc/apt/keyrings P: exit 0" \
      "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "keyrings-dir constraint: /etc/apt/keyrings P: line kept verbatim" \
      "$REPO_P_ETC" "$RENDERED_LINE"
    assert_contains "keyrings-dir constraint: /etc/apt/keyrings P: key lands at sandbox equivalent" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox${P_ETC}"

    # --- (b) case-3 P under /usr/share/keyrings -- still works verbatim. ---
    P_USR="/usr/share/keyrings/foo.gpg"
    REPO_P_USR="deb [arch=amd64 signed-by=${P_USR}] https://example.test/repo stable main"
    OUT="$(call_render seckeep-usr secure-usr "$REPO_P_USR" 'https://example.test/repo/key.asc')"
    assert_eq "keyrings-dir constraint: /usr/share/keyrings P: exit 0" \
      "0" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "keyrings-dir constraint: /usr/share/keyrings P: line kept verbatim" \
      "$REPO_P_USR" "$RENDERED_LINE"
    assert_contains "keyrings-dir constraint: /usr/share/keyrings P: key lands at sandbox equivalent" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:sandbox${P_USR}"

    # --- (c) the reviewer's exploit: signed-by=/etc/cron.d/pwn must be
    # REJECTED, and nothing must be written anywhere under the stage. ---
    P_EXPLOIT="/etc/cron.d/pwn"
    REPO_P_EXPLOIT="deb [arch=amd64 signed-by=${P_EXPLOIT}] https://attacker.test/repo stable main"
    OUT="$(call_render exploit-cron exploit-cron "$REPO_P_EXPLOIT" 'https://attacker.test/repo/key.asc')"
    assert_eq "exploit: signed-by=/etc/cron.d/pwn is REJECTED (nonzero exit)" \
      "1" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    assert_not_contains "exploit: no key file written anywhere under the stage" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:"
    RENDERED_LINE="$(printf '%s\n' "$OUT" | grep '^RENDERED:' | cut -d: -f2-)"
    assert_eq "exploit: no .list file written" \
      "<no .list file written>" "$RENDERED_LINE"

    # --- (d) nested subdirectory under an allowed root must also be
    # rejected -- only DIRECTLY under the two allowed dirs is accepted. ---
    P_NESTED="/etc/apt/keyrings/sub/dir/foo.asc"
    REPO_P_NESTED="deb [arch=amd64 signed-by=${P_NESTED}] https://example.test/repo stable main"
    OUT="$(call_render nested-subdir nested-subdir "$REPO_P_NESTED" 'https://example.test/repo/key.asc')"
    assert_eq "nested subdir under keyrings dir is REJECTED (nonzero exit)" \
      "1" "$(printf '%s\n' "$OUT" | grep '^EXIT:' | cut -d: -f2)"
    assert_not_contains "nested subdir: no key file written anywhere under the stage" \
      <(printf '%s\n' "$OUT" | grep '^KEYFILE:') "KEYFILE:"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - could not extract render_apt_source() body from $CAPTURE_INNER"
  fi
else
  FAIL=$((FAIL + 1))
  echo "FAIL - generated build-in-container.sh not found at $CAPTURE_INNER (cannot run render_apt_source cases)"
fi

# ---------------------------------------------------------------------
# Issue #106 real-run fix: guest apt metadata diet (mkosi.skeleton/) and
# root-partition headroom (mkosi.repart/). Re-run the provisioner with a
# fresh capture so these assertions do not depend on state left over from
# the render_apt_source cases above.
# ---------------------------------------------------------------------
run_provisioner "$BAKE_CONFIG" "2048"
DIET_RUN_EXIT=$?
assert_eq "diet/headroom run reaches container handoff (stub exit 42)" \
  "42" "$DIET_RUN_EXIT"

SKELETON_SOURCES="$CAPTURE_RECIPE/mkosi.skeleton/etc/apt/sources.list.d/bookworm.sources"
if [ -f "$SKELETON_SOURCES" ]; then
  assert_contains "skeleton sources: binary Types only (deb)" \
    "$SKELETON_SOURCES" "Types: deb"
  assert_not_contains "skeleton sources: no deb-src" \
    "$SKELETON_SOURCES" "deb-src"
  assert_not_contains "skeleton sources: no debian-debug repo" \
    "$SKELETON_SOURCES" "debug"
  assert_contains "skeleton sources: main suite present" \
    "$SKELETON_SOURCES" "Suites: bookworm"
  assert_contains "skeleton sources: updates suite present" \
    "$SKELETON_SOURCES" "Suites: bookworm-updates"
  assert_contains "skeleton sources: security suite present" \
    "$SKELETON_SOURCES" "Suites: bookworm-security"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - mkosi.skeleton sources file not found at $SKELETON_SOURCES"
fi

SKELETON_APTCONF="$CAPTURE_RECIPE/mkosi.skeleton/etc/apt/apt.conf.d/99claude-vm-diet.conf"
if [ -f "$SKELETON_APTCONF" ]; then
  assert_contains "skeleton apt.conf.d: Acquire::Languages none" \
    "$SKELETON_APTCONF" 'Acquire::Languages "none";'
  assert_contains "skeleton apt.conf.d: Dir::Cache::pkgcache disabled" \
    "$SKELETON_APTCONF" 'Dir::Cache::pkgcache ""'
  assert_contains "skeleton apt.conf.d: Dir::Cache::srcpkgcache disabled" \
    "$SKELETON_APTCONF" 'Dir::Cache::srcpkgcache ""'
else
  FAIL=$((FAIL + 1))
  echo "FAIL - mkosi.skeleton apt.conf.d diet file not found at $SKELETON_APTCONF"
fi

REPART_ESP="$CAPTURE_RECIPE/mkosi.repart/00-esp.conf"
REPART_ROOT="$CAPTURE_RECIPE/mkosi.repart/10-root.conf"
if [ -f "$REPART_ESP" ] && [ -f "$REPART_ROOT" ]; then
  assert_contains "repart ESP: Type=esp" "$REPART_ESP" "Type=esp"
  assert_contains "repart ESP: 512M sizing (unchanged from mkosi's own default)" \
    "$REPART_ESP" "SizeMinBytes=512M"
  assert_contains "repart root: Type=root" "$REPART_ROOT" "Type=root"
  assert_contains "repart root: Format=ext4" "$REPART_ROOT" "Format=ext4"
  # Bug 1 fix: Minimize=guess is DROPPED so the ext4 filesystem is sized to
  # FILL SizeMinBytes (fs == partition), rather than minimized to a tight fit
  # while SizeMinBytes only padded the GPT slot with dead space (headroom inert).
  assert_not_contains "repart root: Minimize dropped (fs fills the partition, not minimized)" \
    "$REPART_ROOT" "Minimize"
  # 2048 (headroom) + 900 (ROOT_BASE_FLOOR_MB) = 2948.
  assert_contains "repart root: SizeMinBytes reflects base-floor + headroom (2948M)" \
    "$REPART_ROOT" "SizeMinBytes=2948M"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - mkosi.repart/ definition files not found ($REPART_ESP, $REPART_ROOT)"
fi

# Default headroom (unset CLAUDE_VM_ROOT_HEADROOM_MB) resolves to 900+1024=1924M.
run_provisioner "$BAKE_CONFIG" ""
DEFAULT_HEADROOM_EXIT=$?
assert_eq "default-headroom run reaches container handoff (stub exit 42)" \
  "42" "$DEFAULT_HEADROOM_EXIT"
DEFAULT_REPART_ROOT="$CAPTURE_RECIPE/mkosi.repart/10-root.conf"
if [ -f "$DEFAULT_REPART_ROOT" ]; then
  assert_contains "repart root: default headroom yields SizeMinBytes=1924M" \
    "$DEFAULT_REPART_ROOT" "SizeMinBytes=1924M"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - mkosi.repart/10-root.conf not found for default-headroom run"
fi

# An invalid (non-integer) headroom must abort before any container handoff.
run_provisioner "$BAKE_CONFIG" "not-a-number"
BAD_HEADROOM_EXIT=$?
if [ "$BAD_HEADROOM_EXIT" -ne 0 ] && [ "$BAD_HEADROOM_EXIT" -ne 42 ]; then
  PASS=$((PASS + 1))
  echo "ok   - non-integer CLAUDE_VM_ROOT_HEADROOM_MB aborts before container handoff"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - non-integer CLAUDE_VM_ROOT_HEADROOM_MB did not abort as expected (exit=$BAD_HEADROOM_EXIT)"
fi
assert_contains "non-integer headroom: actionable error on stderr" \
  "$WORK/stderr.log" "must be a positive integer"

# ---------------------------------------------------------------------
# Guest self-poweroff getty drop-in (issue #179). The redesigned shutdown model
# makes the guest power ITSELF off when claude quits (exit 0); for that to work
# cleanly the autologin getty must NOT unconditionally respawn the boot launcher
# (a respawn would race the guest's own poweroff on the clean path
# and re-loop claude on the abnormal path, where the launcher has instead handed
# the operator a root login shell). Assert on the ACTUAL generated drop-in the
# provisioner writes into the recipe tree.
#
# MECHANISM (do not conflate the two directives): the respawn comes from
# `Restart=` in the stock serial-getty@.service template, which ships
# `Restart=always`; overriding it to `Restart=no` in the drop-in is the ONLY
# thing that stops systemd restarting the unit. The leading `-` is dropped from
# ExecStart as well, but that prefix does something different -- it only makes a
# nonzero exit be reported as success -- and never governed the respawn. Both
# are asserted, separately, for their own reasons. Regenerate a valid recipe
# first (the prior run aborted on a bad headroom and wrote none).
# ---------------------------------------------------------------------
run_provisioner "$BAKE_CONFIG"
GETTY_RUN_EXIT=$?
assert_eq "getty-check run reaches container handoff (stub exit 42)" "42" "$GETTY_RUN_EXIT"
GETTY_DROPIN="$CAPTURE_RECIPE/mkosi.extra/etc/systemd/system/serial-getty@hvc1.service.d/10-claude-vm.conf"
if [ -f "$GETTY_DROPIN" ]; then
  assert_contains "getty drop-in: boot-launcher ExecStart present" \
    "$GETTY_DROPIN" "boot-launcher.sh"
  # Restart=no is what neutralizes the respawn (overriding the template's
  # Restart=always).
  if grep -qE '^Restart=no$' "$GETTY_DROPIN"; then
    PASS=$((PASS + 1)); echo "ok   - getty drop-in: Restart=no set (this is what neutralizes the respawn)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - getty drop-in: Restart=no set (this is what neutralizes the respawn)"
  fi
  # NO leading `-`: a nonzero launcher exit marks the unit failed rather than
  # being reported as success. Inert here (nothing sets OnFailure=), but pinned
  # so it does not drift back.
  assert_not_contains "getty drop-in: ExecStart has no leading '-' (nonzero exit marks the unit failed)" \
    "$GETTY_DROPIN" "ExecStart=-/sbin/agetty"
  assert_contains "getty drop-in: agetty ExecStart with no leading '-'" \
    "$GETTY_DROPIN" "ExecStart=/sbin/agetty"
  # Exactly ONE ExecStart names the boot launcher: the getty starts it once, as
  # agetty's --login-program. A second one would be an independent re-exec path
  # and could reintroduce the loop.
  DROPIN_LAUNCHER_EXECSTARTS="$(grep -cE '^ExecStart=.*boot-launcher\.sh' "$GETTY_DROPIN")"
  assert_eq "getty drop-in: starts the boot launcher exactly once (no independent re-exec)" \
    "1" "$DROPIN_LAUNCHER_EXECSTARTS"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - getty drop-in not found at $GETTY_DROPIN"
fi

# ---------------------------------------------------------------------
# Baked marketplaces + plugins (issue #107).
#
# The bake step runs the host-verified GUEST-PLATFORM claude binary inside the
# build container -- 'claude plugin marketplace add' / 'claude plugin install'
# with HOME=/root -- and copies the resulting /root/.claude/plugins into the
# image. These assertions exercise the REAL generated artifacts (as the tests
# above do) rather than running a container: the staged manifest and binary,
# and the literal content of the generated in-container step.
# ---------------------------------------------------------------------
FAKE_GUEST_CLAUDE="$WORK/fake-guest-claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_GUEST_CLAUDE"
chmod +x "$FAKE_GUEST_CLAUDE"

# run_provisioner_plugins <bake-plugins-json> [guest-claude-bin]
run_provisioner_plugins() {
  local bake_plugins="$1" guest_bin="${2-$FAKE_GUEST_CLAUDE}"
  PATH="$STUB_BIN:$PATH" \
  CLAUDE_VM_BAKE_CONFIG='{"bake":[],"apt_sources":[]}' \
  CLAUDE_VM_BAKE_PLUGINS="$bake_plugins" \
  CLAUDE_VM_GUEST_CLAUDE_BIN="$guest_bin" \
  bash "$PROVISIONER" "$BOOT_LAUNCHER" "$OUT_IMAGE" \
    >"$WORK/plugins-stdout.log" 2>"$WORK/plugins-stderr.log"
}

BAKE_PLUGINS='{"marketplaces":[{"name":"thevoskamps","url":"https://github.com/TheVoskamps/claude-plugins-marketplace.git"}],"bake":["block-background-agents@thevoskamps"]}'
run_provisioner_plugins "$BAKE_PLUGINS"
PLUGINS_EXIT=$?
assert_eq "plugins: provisioner reaches container handoff (stub exit 42)" \
  "42" "$PLUGINS_EXIT"
assert_not_contains "plugins: no stray command execution on stderr" \
  "$WORK/plugins-stderr.log" "command not found"

# The manifest and the verified binary are staged into the recipe tree so the
# single existing -v $STAGE/recipe:/work/recipe mount carries both.
if [ -f "$CAPTURE_RECIPE/bake-plugins.json" ]; then
  assert_contains "plugins: bake-plugins.json staged into the recipe tree" \
    "$CAPTURE_RECIPE/bake-plugins.json" "block-background-agents@thevoskamps"
  assert_contains "plugins: staged manifest carries the marketplace url" \
    "$CAPTURE_RECIPE/bake-plugins.json" "TheVoskamps/claude-plugins-marketplace.git"
else
  FAIL=$((FAIL + 1)); echo "FAIL - plugins: bake-plugins.json not staged"
fi
if [ -x "$CAPTURE_RECIPE/guest-claude" ]; then
  PASS=$((PASS + 1)); echo "ok   - plugins: verified guest claude binary staged executable"
else
  FAIL=$((FAIL + 1)); echo "FAIL - plugins: verified guest claude binary staged executable"
fi

if [ -f "$CAPTURE_INNER" ]; then
  assert_contains "plugins: in-container step points HOME at the image root" \
    "$CAPTURE_INNER" "export HOME=/root"
  assert_contains "plugins: in-container step adds each marketplace" \
    "$CAPTURE_INNER" 'plugin marketplace add'
  assert_contains "plugins: in-container step installs each bake ref" \
    "$CAPTURE_INNER" 'plugin install'
  # The plugin tree must move with a tar PIPE, not 'cp -a': mkosi.extra lives
  # on the macOS bind mount, which cannot hold security.* xattrs (issue #71,
  # Bug 3) and 'cp -a' would try to preserve them.
  assert_contains "plugins: tree is moved with a tar pipe (bind-mount xattr safety)" \
    "$CAPTURE_INNER" "tar -C /root/.claude/plugins -cf -"
  assert_not_contains "plugins: tree is NOT moved with 'cp -a' (would preserve xattrs)" \
    "$CAPTURE_INNER" "cp -a /root/.claude/plugins"
  # ONLY the plugins tree is baked. The CLI also writes ~/.claude/settings.json
  # and ~/.claude.json; both are host-rendered per run, so copying the build
  # container's copies in would fight the launcher.
  assert_contains "plugins: only the plugins tree is copied into mkosi.extra" \
    "$CAPTURE_INNER" "mkosi.extra/root/.claude/plugins"
  assert_not_contains "plugins: the build container's .claude.json is NOT baked" \
    "$CAPTURE_INNER" "mkosi.extra/root/.claude.json"
  # Build-time failures are HARD (unlike the guest's fail-soft boot phase): a
  # silently plugin-less image would be cached under a version claiming it has
  # them.
  assert_contains "plugins: a failed install fails the build" \
    "$CAPTURE_INNER" "Refusing to bake an image missing a"
  # The registered-name check must compare LITERALLY, never build a grep
  # pattern out of the configured name: a marketplace name may contain '.',
  # which as a regex means "any character", so 'foo.bar' would be accepted
  # against a registered 'fooxbar'.
  assert_contains "plugins: registered-name check uses the literal helper" \
    "$CAPTURE_INNER" 'marketplace_registered "$mp_name"'
  assert_not_contains "plugins: registered-name check builds NO grep regex from the name" \
    "$CAPTURE_INNER" 'grep -qE "(^|[[:space:]])${mp_name}'
else
  FAIL=$((FAIL + 1)); echo "FAIL - plugins: build-in-container.sh not captured"
fi

# ---------------------------------------------------------------------
# Bake-vs-boot marketplace failure policy (issue #226).
#
# A boot-declared marketplace's url only has to be reachable from the GUEST --
# /mnt/repo, a private source, an https host outside the build container's
# egress. Pre-registering it in the image is an optimization, so its add
# failing must WARN and continue; the guest's boot_plugin_phase adds it. A
# BAKE-declared one is a build precondition and must still abort.
#
# Asserted by RUNNING the generated loop, not by grepping it: slice the
# marketplace_registered helper plus the registration loop out of the captured
# build-in-container.sh (the same line-range extraction config-test.sh uses on
# the <<'BOOT' heredoc), repoint /work/recipe at a temp dir, and drive it with
# a stub claude whose exit status the test controls.
# ---------------------------------------------------------------------
MP_POLICY_DIR="$WORK/mp-policy"
mkdir -p "$MP_POLICY_DIR"
MP_STUB="$MP_POLICY_DIR/stub-claude"
cat > "$MP_STUB" <<'STUB'
#!/usr/bin/env bash
if [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "list" ]; then
  cat "$MP_LIST_FILE" 2>/dev/null
  exit 0
fi
if [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "add" ]; then
  exit "${MP_ADD_EXIT:-0}"
fi
exit 0
STUB
chmod +x "$MP_STUB"

MP_SLICE="$MP_POLICY_DIR/marketplace-loop.sh"
MP_SLICE_START=""
MP_SLICE_END=""
if [ -f "$CAPTURE_INNER" ]; then
  MP_SLICE_START="$(grep -n 'marketplace_registered() {' "$CAPTURE_INNER" | head -1 | cut -d: -f1)"
  MP_SLICE_END="$(grep -n 'done < /work/recipe/.bake-marketplaces.tsv' "$CAPTURE_INNER" | head -1 | cut -d: -f1)"
fi
if [ -n "$MP_SLICE_START" ] && [ -n "$MP_SLICE_END" ]; then
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo 'GUEST_CLAUDE="$MP_STUB"'
    awk -v start="$MP_SLICE_START" -v end="$MP_SLICE_END" 'NR >= start && NR <= end' "$CAPTURE_INNER" \
      | sed "s#/work/recipe#$MP_POLICY_DIR#g"
    echo 'echo "BAKED_ITEMS=$BAKED_ITEMS" >&2'
  } > "$MP_SLICE"

  # run_mp_policy <manifest-json> <add-exit> -- returns the loop's exit status,
  # with its stderr in $MP_POLICY_DIR/err.log.
  run_mp_policy() {
    printf '%s' "$1" > "$MP_POLICY_DIR/bake-plugins.json"
    MP_STUB="$MP_STUB" \
    MP_LIST_FILE="$MP_POLICY_DIR/mp-list.txt" \
    MP_ADD_EXIT="$2" \
      bash "$MP_SLICE" >"$MP_POLICY_DIR/out.log" 2>"$MP_POLICY_DIR/err.log"
  }

  MP_BAKE_DECL='{"marketplaces":[{"name":"mp","url":"/mnt/repo","origin":"bake"}],"bake":[]}'
  MP_BOOT_DECL='{"marketplaces":[{"name":"mp","url":"/mnt/repo","origin":"boot"}],"bake":[]}'

  # A failing add on a BAKE-declared marketplace still aborts the build.
  printf 'No marketplaces configured\n' > "$MP_POLICY_DIR/mp-list.txt"
  run_mp_policy "$MP_BAKE_DECL" 1
  assert_eq "mp-policy: a failed add on a bake-declared marketplace aborts" \
    "1" "$?"
  assert_contains "mp-policy: the abort keeps the existing refusal message" \
    "$MP_POLICY_DIR/err.log" "Refusing to bake an image whose"

  # The SAME url declared only in a boot file warns and continues -- this is
  # the issue #226 reproduce case, which used to take the whole build down.
  run_mp_policy "$MP_BOOT_DECL" 1
  assert_eq "mp-policy: a failed add on a boot-declared marketplace continues" \
    "0" "$?"
  assert_contains "mp-policy: ... with a warning that names the marketplace" \
    "$MP_POLICY_DIR/err.log" "failed for 'mp'"
  assert_not_contains "mp-policy: ... and does NOT print the build-refusal message" \
    "$MP_POLICY_DIR/err.log" "Refusing to bake an image whose"
  # Nothing landed, so the tree-copy step below the loop must not demand one.
  assert_contains "mp-policy: a skipped boot-declared add leaves BAKED_ITEMS at 0" \
    "$MP_POLICY_DIR/err.log" "BAKED_ITEMS=0"

  # An add that SUCCEEDS but registers under a different name: still fatal for
  # a bake-declared entry, still best-effort for a boot-declared one.
  printf 'Configured marketplaces:\n\n  x other\n' > "$MP_POLICY_DIR/mp-list.txt"
  run_mp_policy "$MP_BAKE_DECL" 0
  assert_eq "mp-policy: a name mismatch on a bake-declared marketplace aborts" \
    "1" "$?"
  run_mp_policy "$MP_BOOT_DECL" 0
  assert_eq "mp-policy: a name mismatch on a boot-declared marketplace continues" \
    "0" "$?"

  # The happy path counts the registration, so a build that DID register
  # something keeps the strict "tree must exist" check downstream.
  printf 'Configured marketplaces:\n\n  x mp\n' > "$MP_POLICY_DIR/mp-list.txt"
  run_mp_policy "$MP_BOOT_DECL" 0
  assert_eq "mp-policy: a successful add succeeds whatever the origin" "0" "$?"
  assert_contains "mp-policy: ... and counts toward BAKED_ITEMS" \
    "$MP_POLICY_DIR/err.log" "BAKED_ITEMS=1"

  # An origin-less entry (an older or hand-written manifest) is read as
  # bake-declared -- the fail-safe reading.
  printf 'No marketplaces configured\n' > "$MP_POLICY_DIR/mp-list.txt"
  run_mp_policy '{"marketplaces":[{"name":"mp","url":"/mnt/repo"}],"bake":[]}' 1
  assert_eq "mp-policy: an origin-less manifest entry defaults to the strict policy" \
    "1" "$?"

  # An entry with NO url. Its record is name<TAB><TAB>origin, an EMPTY MIDDLE
  # field -- which a tab-IFS `read -r a b c` silently swallows, because a tab is
  # IFS whitespace and a run of them collapses to one separator. That misread
  # the origin as the url, left the origin empty, and so applied the strict
  # policy to a boot-declared entry: the no-url boot branch was unreachable and
  # the build aborted, which is the very failure #226 exists to prevent. Both
  # halves are asserted, so a regression cannot hide behind the bake case.
  MP_BOOT_NO_URL='{"marketplaces":[{"name":"mp","url":"","origin":"boot"}],"bake":[]}'
  MP_BAKE_NO_URL='{"marketplaces":[{"name":"mp","url":"","origin":"bake"}],"bake":[]}'
  run_mp_policy "$MP_BOOT_NO_URL" 0
  assert_eq "mp-policy: a boot-declared entry with no url skips instead of aborting" \
    "0" "$?"
  assert_contains "mp-policy: ... and says so, rather than trying to add its origin as a url" \
    "$MP_POLICY_DIR/err.log" "has no url to pre-register it from"
  assert_not_contains "mp-policy: ... and never treats 'boot' as the url" \
    "$MP_POLICY_DIR/err.log" "adding marketplace 'mp' from boot"
  run_mp_policy "$MP_BAKE_NO_URL" 0
  assert_eq "mp-policy: a bake-declared entry with no url still aborts" \
    "1" "$?"
  assert_contains "mp-policy: ... with the cannot-register message" \
    "$MP_POLICY_DIR/err.log" "has no url; cannot register it in the image"
else
  FAIL=$((FAIL + 1)); echo "FAIL - mp-policy: could not slice the marketplace loop out of build-in-container.sh"
fi

# The tree-copy step must be skipped, not fatal, when nothing was baked.
if [ -f "$CAPTURE_INNER" ]; then
  assert_contains "mp-policy: nothing baked skips the tree copy instead of aborting" \
    "$CAPTURE_INNER" 'if [ "$BAKED_ITEMS" -eq 0 ]; then'
fi

# No plugins configured -> the whole apparatus is inert and no binary is
# needed, so a plugin-less build is byte-identical to the pre-#107 recipe.
run_provisioner_plugins '{"marketplaces":[],"bake":[]}' ""
assert_eq "plugins: unconfigured build still reaches container handoff" \
  "42" "$?"
if [ -f "$CAPTURE_INNER" ]; then
  assert_contains "plugins: unconfigured build renders the bake block inert" \
    "$CAPTURE_INNER" 'if [ "0" -eq 1 ]; then'
fi
if [ -e "$CAPTURE_RECIPE/guest-claude" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL - plugins: unconfigured build must not stage a claude binary"
else
  PASS=$((PASS + 1)); echo "ok   - plugins: unconfigured build stages no claude binary"
fi

# Plugins configured but NO verified binary -> abort BEFORE the container, so
# the operator never gets a cached image that silently lacks them.
run_provisioner_plugins "$BAKE_PLUGINS" ""
assert_eq "plugins: configured-but-no-binary aborts before the container" \
  "1" "$?"
assert_contains "plugins: the abort explains the missing verified binary" \
  "$WORK/plugins-stderr.log" "no verified guest"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "podman-mkosi-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
