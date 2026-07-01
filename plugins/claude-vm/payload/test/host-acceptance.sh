#!/usr/bin/env bash
#
# host-acceptance.sh -- self-contained on-host acceptance test for the
# claude-vm bootable runtime (issue #75's criteria, made runnable by issue
# #100; extended with the verified-cache criterion by issue #49).
#
# Runs the acceptance criteria end-to-end with NO manual choreography:
#
#   (a) the DEFAULT provisioner (podman-mkosi, no CLAUDE_VM_IMAGE_PROVISIONER
#       override) builds a raw EFI guest image with no hand-run
#       build-guest-image.sh and no loop-device step;
#   (b) vfkit boots that image, the guest reaches the claude-fetch SEAM (the
#       observable boot message), and execs the host-verified claude off the
#       /mnt/claudebin RO mount (a STUB claude, asserted by its marker);
#   (c) egress is confined to the allowlist by the bundled tinyproxy proxy:
#       an allowlisted host is permitted, a non-allowlisted host is refused,
#       and an EMPTY allowlist denies all;
#   (d) the host-side GPG-verified claude cache (issue #49), exercised with a
#       LOCALLY-generated key over local fixtures (does NOT reach claude.ai):
#       resolve+fetch+verify+cache works, a tampered manifest aborts, a
#       checksum mismatch aborts, and a warm boot uses the cache with no
#       network. Skips when gpg is absent.
#
# LIVE-NETWORK CAVEAT (criterion (c) only): unlike (a) and (b), criterion
# (c) is NOT fully self-contained -- it probes REAL external hosts
# (example.com, neverssl.com) through the proxy to assert the allow/deny
# behavior, and therefore carries a live outbound-network dependency. A
# transient network failure on the (c) sub-tests is an environment
# problem, not necessarily a proxy defect, and should not be
# misattributed to one. (Criteria (a) and (b) remain self-contained: they
# build and boot locally with no external host dependency.)
#
# Run directly:
#
#   plugins/claude-vm/payload/test/host-acceptance.sh
#
# HOST-GATED, split by cause (issue #110): like config-test.sh skips when
# yq is absent, this test SKIPS (exit 0 with a clear message) when a
# required BINARY (gvproxy, vfkit, podman, tinyproxy, curl) is absent --
# the test cannot install software for the user. But a podman binary that
# is present with only its MACHINE stopped/absent is NOT a skip: starting
# the machine installs nothing, so the test brings it up itself (init+start
# when no machine exists, start-only when one exists but is stopped) and
# tears down exactly what it changed on exit. This keeps the test from
# green-exiting on a fully-equipped host without proving anything.
#
# SKIP vs FAIL (issue #115): the line is "missing software the test won't
# install" -> SKIP (exit 0); "the test tried to bring up a runtime it chose
# to provision and it failed" -> FAIL (exit 1). A failed 'podman machine
# init'/'start' is NOT a "cannot run here" skip -- the runtime is unusable
# and nothing was proven, so exiting 0 there is the precise false-green
# (#57) this test exists to catch. Bring-up failures therefore exit
# non-zero.
#
# DIAGNOSTICS (issue #115): build/boot/proxy logs and the podman machine
# init/start stderr are written to a STABLE, RETAINED per-run directory
# under ${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/logs/<run-id>/ and are
# NOT deleted on exit, so a failed run stays diagnosable. (The earlier code
# logged into a mktemp dir it rm -rf'd on exit, so failure diagnostics --
# including the machine-start error -- were destroyed before they could be
# read.)
#
# Requires (to actually run, not skip): gvproxy (resolved from podman
# libexec), vfkit, podman, tinyproxy, curl. A podman machine is started
# by the test when absent/stopped, rather than required up front.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$(cd "$TEST_DIR/.." && pwd)"
LIB="$PAYLOAD_DIR/lib/config.sh"
BUILD="$PAYLOAD_DIR/build-guest-image.sh"
PROXY_LAUNCH="$PAYLOAD_DIR/proxy/tinyproxy-launch.sh"

# shellcheck source=../lib/config.sh
. "$LIB"

# ---------------------------------------------------------------------
# Host gate, split by cause (issue #110).
#
# The preflight has two categorically different failure modes, and only
# one warrants a SKIP:
#
#   1. A required BINARY is absent (gvproxy, vfkit, podman,
#      tinyproxy, curl) -> SKIP (exit 0). The test cannot install
#      software for the user, exactly as config-test.sh skips on a
#      missing yq.
#
#   2. The binaries are present but podman's MACHINE is stopped/absent
#      -> the test brings the machine up itself. 'podman machine
#      init'/'start' installs nothing; it starts a runtime already
#      present, no different from this test building the guest image or
#      booting vfkit. Skipping here would let the test green-exit on a
#      clean fully-equipped host without proving anything (the
#      "framework with a hole" failure of #57 that this test exists to
#      catch).
#
# So we check binaries first (SKIP on absence), then -- if podman is
# present but its machine isn't running -- start the machine ourselves,
# recording what we changed so teardown can undo exactly that.
# ---------------------------------------------------------------------
# gate_skip is for "this host cannot run the test" -> exit 0. It is
# correct ONLY for a MISSING BINARY the test will not install for the
# user (curl, gvproxy, vfkit, podman, tinyproxy), mirroring how
# config-test.sh skips on a missing yq.
gate_skip() {
  echo "SKIP: $1 host-acceptance test skipped." >&2
  exit 0
}

# gate_fail is for a REAL failure -> exit 1. When the test itself tried
# to bring up a runtime it chose to provision (podman machine init /
# start) and that failed, the runtime is unusable and NOTHING was
# proven. That is NOT a "cannot run here" skip; reporting it as exit 0
# is the precise "framework with a hole" false-green (#57) this test
# exists to catch. Bring-up failures route here, not to gate_skip.
gate_fail() {
  echo "FAIL: $1 host-acceptance test failed." >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || gate_skip "curl not available;"

# Binary presence only -- NOT machine running state. We mirror the
# preflight's binary checks here so a stopped/absent machine does not
# turn into a SKIP. The preflight's combined "default-proxy" run is
# intentionally NOT used as the gate, because it ALSO probes 'podman
# info' and would conflate a stopped machine (which we want to start,
# below) with a missing binary (which we SKIP on). We therefore re-run
# the same per-binary checks the preflight does, minus the 'podman info'
# machine probe. gvproxy ships in podman's libexec rather than on PATH,
# so it uses the resolver; the rest are plain PATH lookups.
claude_vm_resolve_gvproxy >/dev/null 2>&1 || \
  gate_skip "gvproxy not resolvable (install podman);"
for bin in vfkit podman tinyproxy; do
  command -v "$bin" >/dev/null 2>&1 || gate_skip "$bin not available;"
done

# jq parses 'podman machine list --format json' below. The JSON form is
# the ONLY reliable source for the machine name: podman renders the
# DEFAULT machine's '{{.Name}}' Go-template field with a trailing '*'
# default-marker (e.g. 'podman-machine-default*'), and that marker would
# be captured into MACHINE_NAME and break every subsequent 'podman
# machine start/stop/rm "$MACHINE_NAME"' (issue #57). The JSON 'Name' is
# unmarked and 'Running'/'Default' are real booleans. jq is missing
# software the test will not install, so -- like the binaries above -- an
# absent jq is a SKIP, not a FAIL.
command -v jq >/dev/null 2>&1 || gate_skip "jq not available;"

# MACHINE_ACTION records what (if anything) this test did to the podman
# machine, so cleanup can undo EXACTLY that and nothing more:
#   ""      -> machine was already running; leave it completely untouched.
#   "start" -> machine existed but was stopped; we started it -> stop on exit.
#   "init"  -> no machine existed; we init+started it -> stop + rm on exit.
# MACHINE_NAME records the SPECIFIC machine we acted on, so teardown
# targets the same machine the probe inspected rather than relying on the
# implicit "default machine" that bare 'podman machine start/stop/rm'
# operate on (which can differ from the machine we found via 'list').
# Both are declared BEFORE the cleanup trap so the trap (installed next)
# can read their final values even if we gate_fail (or gate_skip)
# mid-bring-up.
MACHINE_ACTION=""
MACHINE_NAME=""

# WORK is the EPHEMERAL scratch for the build artifact (the multi-GB raw
# image, EFI store, sockets). It is fine to delete on exit -- the image
# itself is not a diagnostic.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm-accept.XXXXXX")"

# LOG_DIR is a STABLE, RETAINED, per-run location for diagnostics. The old
# code logged into $WORK and rm -rf'd it on exit, so on ANY failure the
# build/boot/proxy logs -- and the podman machine init/start stderr -- were
# deleted before they could be read (issue #115). Logs now go here instead
# and are NEVER removed on exit, so a failed run is diagnosable after the
# fact. Path mirrors the global config path resolution in lib/config.sh
# (respects XDG_CONFIG_HOME, expands $HOME). A unique per-run id keeps
# concurrent/repeated runs from colliding.
LOG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/logs"
RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
LOG_DIR="$LOG_BASE/$RUN_ID"
mkdir -p "$LOG_DIR"
MACHINE_LOG="$LOG_DIR/podman-machine.log"
SUMMARY_LOG="$LOG_DIR/summary.log"
echo "host-acceptance: diagnostics for this run are retained in: $LOG_DIR" >&2

PIDS_TO_KILL=()
cleanup() {
  local pid
  for pid in "${PIDS_TO_KILL[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  # Only the throwaway image scratch is removed; LOG_DIR is retained so a
  # failed run stays diagnosable (issue #115).
  rm -rf "$WORK"
  # Undo ONLY what this run did to the podman machine. A machine that was
  # already running when we started ("" action) is left fully untouched.
  # Target the SAME machine MACHINE_NAME we brought up, not the implicit
  # default, so probe and teardown agree on the host with multiple/non-
  # default machines. teardown_warn reports (to the log) when a stop/rm we
  # ATTEMPTED did not succeed, rather than silently swallowing the failure
  # with '|| true' and leaving a dirty host with no signal (issue #115).
  case "$MACHINE_ACTION" in
    start)
      echo "host-acceptance: stopping the podman machine we started ($MACHINE_NAME)." >&2
      podman machine stop "$MACHINE_NAME" >>"$MACHINE_LOG" 2>&1 \
        || teardown_warn "'podman machine stop $MACHINE_NAME' failed; the machine may still be running."
      ;;
    init)
      echo "host-acceptance: stopping and removing the podman machine we created ($MACHINE_NAME)." >&2
      podman machine stop "$MACHINE_NAME" >>"$MACHINE_LOG" 2>&1 \
        || teardown_warn "'podman machine stop $MACHINE_NAME' failed; the machine may still be running."
      podman machine rm -f "$MACHINE_NAME" >>"$MACHINE_LOG" 2>&1 \
        || teardown_warn "'podman machine rm -f $MACHINE_NAME' failed; a leftover machine may remain on the host."
      ;;
  esac
  echo "host-acceptance: diagnostics for this run are retained in: $LOG_DIR" >&2
}

# teardown_warn surfaces a teardown failure to BOTH stderr and the log,
# instead of the old '|| true' that silently swallowed it. A stop/rm that
# the test attempted but that did not succeed leaves a dirty host; that
# must be signalled, not hidden.
teardown_warn() {
  echo "host-acceptance: WARNING (teardown): $1" >&2
  echo "WARNING (teardown): $1" >>"$MACHINE_LOG" 2>/dev/null || true
}
# Install the trap BEFORE bringing the machine up, so a gate_fail after a
# successful 'init' (e.g. a failed 'start') still tears down the
# half-built machine on exit.
trap cleanup EXIT INT TERM

if ! podman info >/dev/null 2>&1; then
  # podman binary is present (checked above) but 'podman info' failed.
  # Resolve a SPECIFIC target machine (its name + running state) from a
  # single probe so the bring-up and teardown operate on exactly that
  # machine, not on whatever the implicit "default machine" of a bare
  # 'podman machine start' happens to be.
  #
  # We read from '--format json', NOT the '{{.Name}}'-based Go template,
  # because podman renders the DEFAULT machine's '{{.Name}}' with a
  # trailing '*' default-marker (e.g. 'podman-machine-default*'). That
  # marker is emitted UNCONDITIONALLY by a bare '{{.Name}}' -- it is not
  # contingent on '{{.Default}}' being in the template -- so the old
  # template+cut probe captured 'podman-machine-default*' into
  # MACHINE_NAME, and every later 'podman machine start/stop/rm
  # "$MACHINE_NAME"' then targeted a machine that does not exist by that
  # literal name. On a host whose default machine is stopped, the test
  # could never start it (issue #57). The JSON 'Name' is unmarked and
  # 'Running'/'Default' are real booleans, so selecting the default is a
  # STRUCTURAL read ('.Default==true') rather than a brittle tab-column
  # match. jq emits "<name>\t<running>\t<default>" for the chosen
  # machine: the default-flagged machine if one exists, else the
  # first/sole machine; empty when no machine exists.
  machine_probe="$(podman machine list --format json 2>/dev/null \
    | jq -r '(map(select(.Default==true)) + .)[0]
             | select(. != null)
             | "\(.Name)\t\(.Running)\t\(.Default)"' 2>/dev/null)"

  TARGET_RUNNING=""
  if [ -n "$machine_probe" ]; then
    MACHINE_NAME="$(printf '%s' "$machine_probe" | cut -f1)"
    TARGET_RUNNING="$(printf '%s' "$machine_probe" | cut -f2)"
  fi

  if [ -z "$machine_probe" ]; then
    # No machine at all -> init+start. 'podman machine init' picks the
    # default name; capture it back from the probe so teardown targets it.
    echo "host-acceptance: no podman machine found; initializing one." >&2
    echo "  NOTE: 'podman machine init' is HEAVY -- it downloads a VM image" >&2
    echo "  and provisions a Linux VM. Expect several minutes on first run." >&2
    # 'podman machine init' is invoked bare (no --cpus/--memory). This is
    # INTENTIONAL: this podman machine is the BUILD HOST for the mkosi image
    # build, not the guest VM that claude-vm provisions. The resolved
    # cpus/mem config describes the guest (the vfkit boot below uses fixed
    # acceptance-test sizing too), so honoring it on the build host would
    # conflate two different machines. Sizing the build host is out of scope
    # for this test (issue #115, secondary item).
    # stderr -> MACHINE_LOG so a failed init is diagnosable after the run
    # (previously sent to >&2 and lost when the log dir was deleted, #115).
    if ! podman machine init >>"$MACHINE_LOG" 2>&1; then
      gate_fail "'podman machine init' failed (see $MACHINE_LOG);"
    fi
    MACHINE_ACTION="init"
    # Capture the freshly-initialized machine's name from JSON, NOT from
    # the '{{.Name}}' Go template: a bare '{{.Name}}' appends a '*'
    # default-marker to the default machine's name (issue #57), and the
    # machine 'init' just created IS the default, so the template would
    # hand back 'podman-machine-default*' -- a name no later 'podman
    # machine start/stop/rm' can resolve. The JSON 'Name' is unmarked.
    # Prefer the default-flagged machine, falling back to the first.
    MACHINE_NAME="$(podman machine list --format json 2>/dev/null \
      | jq -r '(map(select(.Default==true)) + .)[0]
               | select(. != null) | .Name' 2>/dev/null)"
    echo "host-acceptance: starting the freshly-initialized podman machine ($MACHINE_NAME)." >&2
    if ! podman machine start "$MACHINE_NAME" >>"$MACHINE_LOG" 2>&1; then
      # init succeeded but start failed: the runtime is unusable. Tear down
      # the half-built machine below via the trap, then FAIL (not skip) --
      # the test provisioned a runtime that did not come up, so exit 0 here
      # would be a false green (#115).
      gate_fail "'podman machine start' failed after init (see $MACHINE_LOG);"
    fi
  elif [ "$TARGET_RUNNING" = "true" ]; then
    # The target machine is ALREADY running, yet 'podman info' failed.
    # That is NOT a stopped-machine condition, so starting it would be a
    # spurious no-op that masks the real cause. Treat it as an
    # environment problem and skip rather than issue a redundant start.
    echo "host-acceptance: podman machine ($MACHINE_NAME) is already running" >&2
    echo "  but 'podman info' failed for a non-machine-state reason." >&2
    gate_skip "podman unusable despite a running machine;"
  else
    echo "host-acceptance: podman machine ($MACHINE_NAME) exists but is stopped; starting it." >&2
    # stderr -> MACHINE_LOG so a failed start is diagnosable after the run.
    if ! podman machine start "$MACHINE_NAME" >>"$MACHINE_LOG" 2>&1; then
      # The test tried to start a stopped machine and it failed -> the
      # runtime is unusable. FAIL, not skip (#115).
      gate_fail "'podman machine start' failed (see $MACHINE_LOG);"
    fi
    MACHINE_ACTION="start"
  fi

  # Confirm the runtime is actually usable now before proceeding. We brought
  # the machine up ourselves; if it is still unusable the bring-up did not
  # achieve its purpose -> FAIL, not skip (#115).
  if ! podman info >/dev/null 2>&1; then
    echo "host-acceptance: podman machine still not usable after start." >&2
    gate_fail "podman machine unavailable after bring-up;"
  fi
fi

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "        $2"; }

GVPROXY_BIN="$(claude_vm_resolve_gvproxy)"

# ---------------------------------------------------------------------
# Criterion (a): default provisioner builds a raw EFI image, no override,
# no loop-device step.
# ---------------------------------------------------------------------
IMG="$WORK/guest.raw"
# Diagnostic logs go to the RETAINED LOG_DIR, not the ephemeral WORK
# scratch, so they survive a failed run (issue #115).
BUILD_LOG="$LOG_DIR/build.log"

# Unset any override so the BUNDLED default provisioner (podman-mkosi) is
# exercised -- the criterion is specifically about the no-override path.
unset CLAUDE_VM_IMAGE_PROVISIONER

if "$BUILD" --output "$IMG" >"$BUILD_LOG" 2>&1; then
  if [ -s "$IMG" ]; then
    pass "(a) default provisioner produced a non-empty raw image"
  else
    fail "(a) image file missing or empty after build" "see $BUILD_LOG"
  fi

  if [ -f "$IMG.version" ] && [ "$(cat "$IMG.version")" = "$("$BUILD" --print-version)" ]; then
    pass "(a) image version stamp matches the pinned version"
  else
    fail "(a) image version stamp missing or mismatched"
  fi

  # No loop-device step: the offline RepartOffline=yes path uses no
  # /dev/loopX. A loop-device attempt would surface in the build log.
  if grep -qiE 'losetup|/dev/loop|loop device' "$BUILD_LOG"; then
    fail "(a) build log mentions a loop device (offline repart expected)" "see $BUILD_LOG"
  else
    pass "(a) build used no loop-device step"
  fi
else
  fail "(a) default provisioner build failed" "see $BUILD_LOG"
  IMG=""  # downstream boot test cannot run
fi

# ---------------------------------------------------------------------
# Criterion (b): vfkit boots the image and the guest reaches the seam.
# The seam emits an observable message (see build-guest-image.sh's
# emit_boot_launcher). We boot with a console captured to a file and
# assert the message appears, then stop the VM.
# ---------------------------------------------------------------------
# The seam message the boot launcher emits when it reaches the claude-fetch
# seam. Both branches of the (now-filled) seam print this prefix -- the
# "running host-verified claude" branch when the claudebin mount carries an
# executable, and the "no verified claude binary" branch when it does not --
# so asserting the prefix confirms the guest reached the seam regardless of
# which branch ran. (issue #49 filled the seam; this marker is the boundary,
# not the old stop-here message.)
SEAM_MARKER="guest booted to the claude-fetch seam"
if [ -n "$IMG" ] && [ -s "$IMG" ]; then
  BOOT_LOG="$LOG_DIR/boot.log"     # retained diagnostic (issue #115)
  EFISTORE="$WORK/efistore"
  GVSOCK="$WORK/vfkit-net.sock"

  # gvproxy provides the guest's network so the boot launcher's
  # network-online.target is satisfiable.
  "$GVPROXY_BIN" --listen-vfkit "unixgram://$GVSOCK" >/dev/null 2>&1 &
  PIDS_TO_KILL+=("$!")
  for _ in $(seq 1 50); do [ -S "$GVSOCK" ] && break; sleep 0.1; done

  # Boot the image the SAME WAY the real launcher (claude-vm.sh) does: it
  # ALWAYS attaches these virtio-fs shares -- mountTag=runconfig (the run.env
  # the guest boot launcher sources), mountTag=repo (the working tree),
  # mountTag=claudebin (the host-verified claude binary, issue #49), and
  # mountTag=claudecreds (the host's claude.ai OAuth credential, issue #50).
  # Testing the real thing means reproducing that mount topology here; a
  # bare boot (no shares) is a boot the product never actually performs, and
  # would make the guest's `. /mnt/runconfig/run.env` fail in the test while
  # "passing" in reality (or vice versa). We stand up throwaway shares:
  #   - runconfig: a STUB run.env with the same KEYS the real one carries
  #     (claude-vm.sh writes HTTP(S)_PROXY/NO_PROXY/REPO_TAG/POLICY_TAG/
  #     CLAUDEBIN_TAG/CLAUDECREDS_TAG/CLAUDE_ARGS) but DUMMY values. run.env
  #     no longer carries any secret -- auth is the claudecreds mount below.
  #   - repo: an empty dir the seam cd's into (the stub claude does not
  #     require repo contents).
  #   - claudebin: the dir holding the (host-verified) claude binary, shared
  #     RO under mountTag=claudebin (issue #49). The real launcher caches a
  #     GPG-verified binary here; for THIS boot test we stand up a STUB
  #     `claude` that prints a recognizable marker and exits, so the seam's
  #     `exec "$CLAUDE_BIN" $CLAUDE_ARGS` actually runs and we can confirm
  #     the guest ran the mounted binary (not just reached the seam). The
  #     stub is shell, run by the guest's /bin/sh -- adequate to prove the
  #     mount+exec path without a real linux-arm64 claude artifact.
  #   - claudecreds: the dir holding the host's claude.ai OAuth credential,
  #     shared RO under mountTag=claudecreds (issue #50). The real launcher
  #     extracts it from the macOS Keychain; for THIS boot test we stand up a
  #     STUB .credentials.json so the boot launcher's credential-install step
  #     (copy to $HOME/.claude/.credentials.json) runs without aborting under
  #     `set -e`. Its content is a non-secret placeholder; the stub claude
  #     never reads it. The SAME dir also carries a STUB claude-json-seed.json
  #     (issue #88): the real launcher writes the host's selected identity seed
  #     (userID + oauthAccount) here, and the boot launcher installs it at
  #     $HOME/.claude.json before exec'ing claude. Unlike the credential, a
  #     MISSING seed is tolerated (logged, not fatal) -- but we still stand up a
  #     placeholder so the install path is exercised. Its content is a
  #     non-secret placeholder; the stub claude never reads it.
  RUNCONFIG_SHARE="$WORK/runconfig"
  REPO_SHARE="$WORK/repo"
  CLAUDEBIN_SHARE="$WORK/claudebin"
  CLAUDECREDS_SHARE="$WORK/claudecreds"
  mkdir -p "$RUNCONFIG_SHARE" "$REPO_SHARE" "$CLAUDEBIN_SHARE" "$CLAUDECREDS_SHARE"
  # CLAUDE_VM_COLUMNS/LINES (issue #88): the real launcher writes the host
  # `stty size` here; this headless boot test has no controlling terminal, so
  # they are EMPTY -- the boot launcher then skips the `stty` geometry seed and
  # the guest keeps its 80x24 default. (Empty mirrors what the real launcher
  # writes when claude-vm is invoked from a non-tty.) The renderer CLAUDE_CODE_*
  # vars are intentionally absent here (claude.renderer unset).
  cat > "$RUNCONFIG_SHARE/run.env" <<'RUNENV'
HTTPS_PROXY=http://192.168.127.1:8080
HTTP_PROXY=http://192.168.127.1:8080
NO_PROXY=localhost,127.0.0.1
REPO_TAG=repo
POLICY_TAG=policy
CLAUDEBIN_TAG=claudebin
CLAUDECREDS_TAG=claudecreds
CLAUDE_VM_COLUMNS=
CLAUDE_VM_LINES=
CLAUDE_ARGS=--version
RUNENV
  # Stub claude: prints a marker the boot test asserts, proving the guest
  # exec'd the mounted binary off /mnt/claudebin.
  cat > "$CLAUDEBIN_SHARE/claude" <<'STUBCLAUDE'
#!/bin/sh
echo "claude-vm-stub: ran host-verified claude off the mount, args=[$*]"
STUBCLAUDE
  chmod 0755 "$CLAUDEBIN_SHARE/claude"
  # Stub OAuth credential: a non-secret placeholder so the boot launcher's
  # credential-install step has a file to copy into $HOME/.claude/. The stub
  # claude never reads it.
  printf '{"placeholder":"not-a-real-credential"}\n' > "$CLAUDECREDS_SHARE/.credentials.json"
  chmod 0600 "$CLAUDECREDS_SHARE/.credentials.json"
  # Stub identity seed (issue #88): a non-secret placeholder so the boot
  # launcher's seed-install step (copy to $HOME/.claude.json) is exercised. The
  # real launcher writes the host's selected {userID, oauthAccount} here; a
  # missing seed is tolerated by the boot launcher, but we provide one so the
  # install path runs. The stub claude never reads it.
  printf '{"userID":"stub-user-id","oauthAccount":{"emailAddress":"stub@example.invalid"}}\n' \
    > "$CLAUDECREDS_SHARE/claude-json-seed.json"
  chmod 0600 "$CLAUDECREDS_SHARE/claude-json-seed.json"

  # Boot the guest, capturing serial console. vfkit runs in the
  # background; we poll the console for the seam marker, then stop it.
  # The virtio-fs devices mirror claude-vm.sh's always-present mounts.
  #
  # Dual virtio-serial topology (issue #88): the real launcher attaches a
  # FIRST virtio-serial (logFilePath -> guest hvc0, the boot capture) and a
  # SECOND (stdio -> guest hvc1, the interactive console claude runs on via the
  # autologin serial-getty@hvc1). This HEADLESS test has no controlling tty, so
  # it cannot use `stdio` for hvc1; instead it attaches the second console as a
  # SECOND logFilePath capture (HVC1_LOG) so the device EXISTS -- otherwise
  # serial-getty@hvc1 has no tty to bind and the boot launcher (the getty's
  # login program) never runs, so the seam marker never appears. The boot
  # launcher routes its diagnostics to /dev/console (hvc0 = BOOT_LOG), so the
  # seam marker still lands in BOOT_LOG regardless of which console claude's own
  # stdio is on. Device ORDER is load-bearing: 1st -> hvc0, 2nd -> hvc1.
  HVC1_LOG="$LOG_DIR/hvc1.log"     # retained diagnostic (issue #115)
  vfkit \
    --cpus 2 --memory 2048 \
    --bootloader "efi,variable-store=$EFISTORE,create" \
    --device "virtio-blk,path=$IMG" \
    --device "virtio-fs,sharedDir=$REPO_SHARE,mountTag=repo" \
    --device "virtio-fs,sharedDir=$RUNCONFIG_SHARE,mountTag=runconfig" \
    --device "virtio-fs,sharedDir=$CLAUDEBIN_SHARE,mountTag=claudebin" \
    --device "virtio-fs,sharedDir=$CLAUDECREDS_SHARE,mountTag=claudecreds" \
    --device "virtio-net,unixSocketPath=$GVSOCK" \
    --device "virtio-rng" \
    --device "virtio-serial,logFilePath=$BOOT_LOG" \
    --device "virtio-serial,logFilePath=$HVC1_LOG" \
    >>"$BOOT_LOG" 2>&1 &
  VFKIT_PID="$!"
  PIDS_TO_KILL+=("$VFKIT_PID")

  reached_seam=0
  for _ in $(seq 1 120); do  # up to ~120s for a cold boot
    if [ -f "$BOOT_LOG" ] && grep -q "$SEAM_MARKER" "$BOOT_LOG"; then
      reached_seam=1
      break
    fi
    kill -0 "$VFKIT_PID" 2>/dev/null || break  # VM exited
    sleep 1
  done
  kill "$VFKIT_PID" 2>/dev/null || true

  if [ "$reached_seam" -eq 1 ]; then
    pass "(b) vfkit booted the guest and it reached the claude-fetch seam"
  else
    fail "(b) guest did not reach the claude-fetch seam within timeout" "see $BOOT_LOG"
  fi

  # (b2) The seam is FILLED (issue #49): the guest should have exec'd the
  # claude binary off the /mnt/claudebin RO mount. Our stub prints a marker;
  # asserting it confirms the mount+exec path, not merely reaching the seam.
  #
  # Where the marker lands (issue #88): the boot launcher now runs as the
  # autologin serial-getty@hvc1 login program and `exec`s claude with hvc1 as
  # its controlling tty -- so the stub claude's STDOUT marker goes to hvc1
  # (HVC1_LOG), NOT to the hvc0 boot console (BOOT_LOG, where the launcher's own
  # /dev/console diagnostics go). Search BOTH logs so the assertion is robust to
  # exactly which console carries the stub's stdout.
  STUB_MARKER="claude-vm-stub: ran host-verified claude off the mount"
  if grep -q "$STUB_MARKER" "$BOOT_LOG" 2>/dev/null \
     || grep -q "$STUB_MARKER" "$HVC1_LOG" 2>/dev/null; then
    pass "(b) guest exec'd the host-verified claude off the /mnt/claudebin mount"
  else
    fail "(b) guest did not run the mounted claude binary at the seam" "see $BOOT_LOG and $HVC1_LOG"
  fi
else
  fail "(b) skipped: no bootable image from criterion (a)"
fi

# ---------------------------------------------------------------------
# Criterion (c): egress confinement via the bundled tinyproxy proxy.
#   allowlisted host  -> permitted
#   non-allowlisted   -> refused
#   empty allowlist   -> denies all (fail-closed)
#
# We start the proxy the same way claude-vm.sh does (via env vars it
# exports) and probe through it with curl --proxy. The probes use HTTP
# CONNECT semantics; a permitted host returns a non-403 result, a
# refused host returns tinyproxy's 403 (or a connection refusal at the
# CONNECT stage).
# ---------------------------------------------------------------------
PROXY_PORT_C=13128
PROXY_LOG="$LOG_DIR/proxy.log"   # retained diagnostic (issue #115)

# start_proxy <allowlist-file> -> sets PROXY_PID_C, waits for the listener.
# CLAUDE_VM_PROXY_LISTEN_ADDR is intentionally NOT set here: production
# relies on tinyproxy-launch.sh's default (127.0.0.1), so the test
# exercises that real default-resolution path. The curl probes target
# 127.0.0.1:$PROXY_PORT_C, which that loopback default serves.
start_proxy() {
  local allowlist="$1"
  CLAUDE_VM_EGRESS_ALLOWLIST="$allowlist" \
  CLAUDE_VM_PROXY_PORT="$PROXY_PORT_C" \
    "$PROXY_LAUNCH" >>"$PROXY_LOG" 2>&1 &
  PROXY_PID_C="$!"
  PIDS_TO_KILL+=("$PROXY_PID_C")
  # Wait for the port to accept connections.
  local i
  for i in $(seq 1 50); do
    if curl -s -o /dev/null --max-time 2 \
        --proxy "http://127.0.0.1:$PROXY_PORT_C" "http://127.0.0.1/" 2>/dev/null; then
      break
    fi
    kill -0 "$PROXY_PID_C" 2>/dev/null || break
    sleep 0.1
  done
}

stop_proxy() {
  [ -n "${PROXY_PID_C:-}" ] && kill "$PROXY_PID_C" 2>/dev/null || true
  PROXY_PID_C=""
  sleep 0.3
}

# probe_https <host> -> prints "ALLOW" if the proxy OPENED the CONNECT
# tunnel, "DENY" if the proxy REFUSED it, "INDETERMINATE" if neither signal
# was observed.
#
# The verdict reads the PROXY'S OWN CONNECT RESPONSE, not curl's transport
# exit code. tinyproxy answers the CONNECT with one of two unambiguous
# status lines:
#
#   HTTP/1.1 200 Connection established   -> proxy opened the tunnel  (ALLOW)
#   HTTP/1.1 403 ...                      -> proxy refused the host    (DENY)
#
# This is the only signal that actually means "egress confinement". The
# earlier implementation inferred from curl's exit code, but a proxy
# CONNECT refusal and a real upstream RECV error BOTH surface as curl exit
# 56 (CURLE_RECV_ERROR) with %{http_code}=000 -- the proxy's 403 is on the
# TUNNEL, never in the body code -- so exit 56 was misread as ALLOW and a
# correctly-refused host falsely reported as "not refused". Reading the
# proxy's status line is unambiguous AND independent of whether the live
# upstream answers, so it does not flake on a slow/unreachable upstream.
probe_https() {
  local host="$1" v
  # -sv: silent body, verbose protocol trace (the CONNECT exchange) to
  # stderr, which we capture. -o /dev/null discards any body. The transport
  # exit code is deliberately ignored; the proxy's status line is the truth.
  v="$(curl -sv -o /dev/null --max-time 8 \
    --proxy "http://127.0.0.1:$PROXY_PORT_C" \
    "https://$host/" 2>&1)"
  if printf '%s\n' "$v" | grep -qiE '^< HTTP/[0-9.]+ 403'; then
    echo "DENY"
  elif printf '%s\n' "$v" | grep -qiE '^< HTTP/[0-9.]+ 200'; then
    echo "ALLOW"
  else
    # Neither status line seen (e.g. the proxy never answered the CONNECT).
    # Report it distinctly rather than guessing; the caller treats anything
    # that is not the asserted outcome as a failure.
    echo "INDETERMINATE"
  fi
}

# Sub-test c1+c2: a populated allowlist permits the allowlisted host and
# refuses a non-allowlisted host.
ALLOWLIST_C="$WORK/egress.allow"
printf 'example.com\n' > "$ALLOWLIST_C"
start_proxy "$ALLOWLIST_C"

if [ "$(probe_https example.com)" = "ALLOW" ]; then
  pass "(c) allowlisted host (example.com) is permitted"
else
  fail "(c) allowlisted host was refused" "see $PROXY_LOG"
fi

if [ "$(probe_https neverssl.com)" = "DENY" ]; then
  pass "(c) non-allowlisted host (neverssl.com) is refused"
else
  fail "(c) non-allowlisted host was NOT refused" "see $PROXY_LOG"
fi
stop_proxy

# Sub-test c3: an EMPTY allowlist denies all (fail-closed). Even the host
# that WOULD be allowed under a populated allowlist (example.com) must be
# refused when the allowlist is empty.
EMPTY_ALLOWLIST_C="$WORK/egress.empty"
: > "$EMPTY_ALLOWLIST_C"
start_proxy "$EMPTY_ALLOWLIST_C"

if [ "$(probe_https example.com)" = "DENY" ]; then
  pass "(c) empty allowlist denies all (fail-closed)"
else
  fail "(c) empty allowlist did NOT deny all" "see $PROXY_LOG"
fi
stop_proxy

# ---------------------------------------------------------------------
# Criterion (d): host-side GPG-verified claude cache (issue #49).
#
#   d1: a channel/pin resolves to a concrete version, the binary is fetched,
#       its GPG-signed manifest is verified, its checksum is verified, and
#       the binary is cached keyed on the resolved version.
#   d2: a TAMPERED manifest (gpg --verify fails) ABORTS -- nothing cached.
#   d3: a checksum MISMATCH ABORTS -- nothing cached.
#   d4: a WARM boot (already cached) returns the binary with NO network.
#
# This exercises the REAL gpg verification path with a REAL, locally-
# generated signing key over REAL local fixtures -- it does NOT reach
# claude.ai (the live download host needs the operator's out-of-band-
# trusted key, which a CI host does not have). The fetch primitive is
# pointed at local fixture files so the whole pipeline runs self-contained.
# Gated on gpg + a sha256 tool; SKIPs (not fails) when gpg is absent, like
# the binary gates above -- the test will not install gpg for the user.
# ---------------------------------------------------------------------
. "$PAYLOAD_DIR/lib/claude-cache.sh"

if ! command -v gpg >/dev/null 2>&1; then
  echo "ok   - (d) host-side verified-cache test SKIPPED (gpg not available)"
elif ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "ok   - (d) host-side verified-cache test SKIPPED (no sha256 tool)"
else
  # Isolated GNUPGHOME + cache dir so we never touch the operator's real
  # keyring or ~/.config/claude-vm/cache.
  D_HOME="$WORK/gpg-d"
  mkdir -p "$D_HOME"; chmod 700 "$D_HOME"
  export GNUPGHOME="$D_HOME"
  export CLAUDE_VM_CACHE_DIR="$WORK/cache-d"
  export CLAUDE_VM_CACHE_STATE_FILE="$WORK/cache-d-state"

  # Generate a throwaway signing key non-interactively. This is the key we
  # PIN the verify path to (issue #49 review): a bare gpg --verify trusts
  # ANY key in the keyring, so we bind "valid signature" to "this key" by
  # setting CLAUDE_VM_SIGNING_KEY_FINGERPRINT to its fingerprint.
  # `... default sign never` -> an explicitly sign-capable primary key, so
  # d5 below can actually sign with the SECOND key (a `default default` key's
  # primary may be encryption-only -> "Unusable secret key" when signed with).
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'claude-vm acceptance <accept@example.invalid>' \
    default sign never >>"$LOG_DIR/gpg.log" 2>&1
  # The pinned (expected) fingerprint: the FIRST fpr line is the primary key.
  export CLAUDE_VM_SIGNING_KEY_FINGERPRINT="$(gpg --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"

  # A SECOND, unrelated sign-capable key also in the keyring. d5 signs a valid
  # manifest with THIS key; the pin must reject it even though gpg --verify
  # alone would exit 0 (the signature is valid -- just by the wrong key).
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'claude-vm rogue <rogue@example.invalid>' \
    default sign never >>"$LOG_DIR/gpg.log" 2>&1
  ROGUE_FPR="$(gpg --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/{print $10}' | grep -v "^$CLAUDE_VM_SIGNING_KEY_FINGERPRINT$" | head -n1)"

  # Fixtures: a fake binary + a manifest carrying its real sha256, signed
  # with the throwaway key.
  D_FIX="$WORK/fix-d"; mkdir -p "$D_FIX"
  printf 'fake-claude-acceptance-binary\n' > "$D_FIX/claude"
  D_SHA="$(claude_cache_file_sha256 "$D_FIX/claude")"
  cat > "$D_FIX/manifest.good.json" <<JSON
{ "platforms": { "linux-arm64": { "checksum": "$D_SHA" } } }
JSON
  cat > "$D_FIX/manifest.bad.json" <<JSON
{ "platforms": { "linux-arm64": { "checksum": "0000000000000000000000000000000000000000000000000000000000000000" } } }
JSON
  # Sign the GOOD manifest only. (A tampered manifest's signature would not
  # validate -- which is exactly d2.)
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --detach-sign -o "$D_FIX/manifest.good.json.sig" "$D_FIX/manifest.good.json" \
    >>"$LOG_DIR/gpg.log" 2>&1

  # Point the cache's fetch primitive at the local fixtures. d_serve_manifest
  # selects which manifest (good/bad) the manifest URL returns.
  D_RESOLVED="3.2.1"
  D_MANIFEST="$D_FIX/manifest.good.json"
  D_SIG="$D_FIX/manifest.good.json.sig"
  claude_cache_fetch_url() {
    case "$1" in
      */claude-code-releases/stable|*/claude-code-releases/latest)
        printf '%s\n' "$D_RESOLVED" ;;
      */manifest.json)      cat "$D_MANIFEST" ;;
      */manifest.json.sig)  cat "$D_SIG" ;;
      */linux-arm64/claude) cat "$D_FIX/claude" ;;
      *) return 1 ;;
    esac
  }
  # claude_cache_gpg_verify is NOT stubbed -- the REAL gpg runs against the
  # throwaway key, so d1's "verified" and d2's "tamper aborts" are genuine.

  # d1: happy path caches a verified binary.
  if d_out="$(claude_cache_ensure stable 2>>"$LOG_DIR/cache-d.log")" \
     && [ -s "$d_out" ] \
     && [ "$(cat "$CLAUDE_VM_CACHE_STATE_FILE" 2>/dev/null)" = "cold" ]; then
    pass "(d) resolve+fetch+gpg-verify+checksum caches the binary"
  else
    fail "(d) verified-cache happy path did not cache the binary" "see $LOG_DIR/cache-d.log"
  fi

  # d2: a tampered manifest -- serve the BAD manifest but the GOOD sig, so
  # gpg --verify fails (signature does not match the swapped content). Use a
  # fresh version so a prior cache entry cannot mask the abort.
  D_RESOLVED="3.2.2"; D_MANIFEST="$D_FIX/manifest.bad.json"; D_SIG="$D_FIX/manifest.good.json.sig"
  if claude_cache_ensure stable >>"$LOG_DIR/cache-d.log" 2>&1; then
    fail "(d) tampered manifest did NOT abort (verified-cache returned success)"
  elif [ -e "$CLAUDE_VM_CACHE_DIR/3.2.2/linux-arm64/claude" ]; then
    fail "(d) tampered manifest aborted but LEFT a cached binary"
  else
    pass "(d) tampered manifest (gpg --verify fails) aborts and caches nothing"
  fi

  # d3: checksum mismatch -- a CORRECTLY-SIGNED bad-checksum manifest. Sign
  # the bad manifest so gpg --verify passes; the checksum step must then
  # catch the mismatch and abort.
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --detach-sign -o "$D_FIX/manifest.bad.json.sig" "$D_FIX/manifest.bad.json" \
    >>"$LOG_DIR/gpg.log" 2>&1
  D_RESOLVED="3.2.3"; D_MANIFEST="$D_FIX/manifest.bad.json"; D_SIG="$D_FIX/manifest.bad.json.sig"
  if claude_cache_ensure stable >>"$LOG_DIR/cache-d.log" 2>&1; then
    fail "(d) checksum mismatch did NOT abort"
  elif [ -e "$CLAUDE_VM_CACHE_DIR/3.2.3/linux-arm64/claude" ]; then
    fail "(d) checksum mismatch aborted but LEFT a cached binary"
  else
    pass "(d) checksum mismatch (good signature, wrong digest) aborts and caches nothing"
  fi

  # d5: KEY PINNING -- a manifest validly signed by an UNEXPECTED key must
  # be rejected (issue #49 review). We sign the good manifest with the rogue
  # key (also in the keyring, so a bare gpg --verify would exit 0) and serve
  # that signature; the pin (CLAUDE_VM_SIGNING_KEY_FINGERPRINT = the FIRST
  # key) must abort. Skips if the rogue key did not generate.
  if [ -n "${ROGUE_FPR:-}" ]; then
    gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
      --default-key "$ROGUE_FPR" \
      --detach-sign -o "$D_FIX/manifest.rogue.json.sig" "$D_FIX/manifest.good.json" \
      >>"$LOG_DIR/gpg.log" 2>&1
    D_RESOLVED="3.2.4"; D_MANIFEST="$D_FIX/manifest.good.json"; D_SIG="$D_FIX/manifest.rogue.json.sig"
    if claude_cache_ensure stable >>"$LOG_DIR/cache-d.log" 2>&1; then
      fail "(d) signature by an UNEXPECTED key did NOT abort (key pin not enforced)"
    elif [ -e "$CLAUDE_VM_CACHE_DIR/3.2.4/linux-arm64/claude" ]; then
      fail "(d) unexpected-key signature aborted but LEFT a cached binary"
    else
      pass "(d) valid signature by an unexpected key is rejected by the fingerprint pin"
    fi
  else
    echo "ok   - (d) key-pin (unexpected-key) sub-test SKIPPED (rogue key did not generate)"
  fi

  # d4: warm boot -- a PINNED, already-cached version uses NO network. Prove
  # it by making the fetch primitive fail loudly; a warm hit must not call it.
  # Reuse the version cached in d1 by re-resolving stable to it first... but
  # d1 cached 3.2.1, so request it as a pin.
  claude_cache_fetch_url() { echo "(d) WARM boot must not touch the network: $1" >>"$LOG_DIR/cache-d.log"; return 1; }
  if d_out="$(claude_cache_ensure 3.2.1 2>>"$LOG_DIR/cache-d.log")" \
     && [ -s "$d_out" ] \
     && [ "$(cat "$CLAUDE_VM_CACHE_STATE_FILE" 2>/dev/null)" = "warm" ]; then
    pass "(d) warm boot uses the cached binary with no network fetch"
  else
    fail "(d) warm boot did not use the cache without network" "see $LOG_DIR/cache-d.log"
  fi

  unset GNUPGHOME CLAUDE_VM_SIGNING_KEY_FINGERPRINT
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "host-acceptance: $PASS passed, $FAIL failed"
# Retain the pass/fail summary alongside the other diagnostics (#115).
{
  echo "host-acceptance run $RUN_ID"
  echo "result: $PASS passed, $FAIL failed"
} >"$SUMMARY_LOG" 2>/dev/null || true
echo "host-acceptance: diagnostics retained in: $LOG_DIR"
[ "$FAIL" -eq 0 ]
