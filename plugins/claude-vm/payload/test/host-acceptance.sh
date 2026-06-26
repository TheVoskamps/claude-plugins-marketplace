#!/usr/bin/env bash
#
# host-acceptance.sh -- self-contained on-host acceptance test for the
# claude-vm bootable runtime (issue #75's acceptance criteria, made
# runnable by issue #100).
#
# Runs the three issue-#75 acceptance criteria end-to-end with NO manual
# choreography:
#
#   (a) the DEFAULT provisioner (podman-mkosi, no CLAUDE_VM_IMAGE_PROVISIONER
#       override) builds a raw EFI guest image with no hand-run
#       build-guest-image.sh and no loop-device step;
#   (b) vfkit boots that image and the guest reaches the claude-fetch SEAM
#       (the observable boot message the seam emits);
#   (c) egress is confined to the allowlist by the bundled tinyproxy proxy:
#       an allowlisted host is permitted, a non-allowlisted host is refused,
#       and an EMPTY allowlist denies all.
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
  # ALWAYS attaches two virtio-fs shares -- mountTag=runconfig (the run.env
  # the guest boot launcher sources) and mountTag=repo (the working tree).
  # Testing the real thing means reproducing that mount topology here; a
  # bare boot (no shares) is a boot the product never actually performs, and
  # would make the guest's `. /mnt/runconfig/run.env` fail in the test while
  # "passing" in reality (or vice versa). We stand up throwaway shares:
  #   - runconfig: a STUB run.env with the same KEYS the real one carries
  #     (claude-vm.sh writes ANTHROPIC_API_KEY/HTTP(S)_PROXY/NO_PROXY/
  #     REPO_TAG/POLICY_TAG/CLAUDE_ARGS) but DUMMY, non-secret values. Slice
  #     3 stops at the seam BEFORE any token is used, so a placeholder token
  #     is sufficient to exercise the real sourcing path.
  #   - repo: an empty dir (slice 3 does not yet exec against it).
  RUNCONFIG_SHARE="$WORK/runconfig"
  REPO_SHARE="$WORK/repo"
  mkdir -p "$RUNCONFIG_SHARE" "$REPO_SHARE"
  cat > "$RUNCONFIG_SHARE/run.env" <<'RUNENV'
ANTHROPIC_API_KEY=test-placeholder-not-a-real-token
HTTPS_PROXY=http://192.168.127.1:8080
HTTP_PROXY=http://192.168.127.1:8080
NO_PROXY=localhost,127.0.0.1
REPO_TAG=repo
POLICY_TAG=policy
CLAUDE_ARGS=
RUNENV

  # Boot the guest, capturing serial console. vfkit runs in the
  # background; we poll the console for the seam marker, then stop it.
  # The two virtio-fs devices mirror claude-vm.sh's always-present mounts.
  vfkit \
    --cpus 2 --memory 2048 \
    --bootloader "efi,variable-store=$EFISTORE,create" \
    --device "virtio-blk,path=$IMG" \
    --device "virtio-fs,sharedDir=$REPO_SHARE,mountTag=repo" \
    --device "virtio-fs,sharedDir=$RUNCONFIG_SHARE,mountTag=runconfig" \
    --device "virtio-net,unixSocketPath=$GVSOCK" \
    --device "virtio-rng" \
    --device "virtio-serial,logFilePath=$BOOT_LOG" \
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
