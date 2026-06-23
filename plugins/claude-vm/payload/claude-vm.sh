#!/usr/bin/env bash
#
# claude-vm.sh -- launch Claude Code inside an isolated macOS VM.
#
# Config-driven replacement for the original env-var launcher. Every
# non-secret operational knob (cpus, mem, guest_image, proxy, egress
# allowlist, extra mounts, repo mount strategy) comes from layered YAML:
#
#   global:   ~/.config/claude-vm/config.yml   (machine-wide defaults)
#   per-repo: <repo>/.claude-vm/config.yml      (project-specific)
#
# Scalars: repo overrides global. Lists (egress.allow, mounts): union.
# See payload/lib/config.sh for the layering implementation and
# skills/claude-vm/SKILL.md for the full config schema.
#
# The ONLY secret is ANTHROPIC_VM_TOKEN, supplied as an env var (never
# in YAML) and passed to the guest at runtime.
#
# Usage:
#   claude-vm.sh <repo-path> [claude args...]
#
# Requires: yq, git, gvproxy, vfkit, podman (with a started machine),
# and a forward proxy (proxy.cmd; the bundled default needs tinyproxy).
# gvproxy is resolved from podman's libexec, not required on PATH (it
# ships inside the podman formula and is off PATH after a stock
# 'brew install podman'). A dependency preflight checks all of these up
# front. A real boot needs macOS virtualization tooling; this script is
# structured so the config-resolution half is exercisable without it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

# ---------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------
REPO_SRC="${1:?usage: claude-vm <repo-path> [claude args...]}"
shift
CLAUDE_ARGS=("$@")

# Resolve to an absolute repo root so per-repo config and clone work
# regardless of the caller's cwd.
REPO_SRC="$(cd "$REPO_SRC" && git rev-parse --show-toplevel 2>/dev/null || (cd "$REPO_SRC" && pwd))"

# Secret: env var only, never config. Fail fast if unset.
SCOPED_TOKEN="${ANTHROPIC_VM_TOKEN:?set ANTHROPIC_VM_TOKEN to the scoped key for the guest (never store it in config.yml)}"

claude_vm_require_yq || exit 1
command -v git >/dev/null 2>&1 || { echo "claude-vm: git is required" >&2; exit 1; }

# ---------------------------------------------------------------------
# Resolve effective config (layer global + per-repo)
# ---------------------------------------------------------------------
GLOBAL_CONFIG="$CLAUDE_VM_GLOBAL_CONFIG"
REPO_CONFIG="${CLAUDE_VM_REPO_CONFIG:-$REPO_SRC/.claude-vm/config.yml}"

# NOTE: the merged-config temp file is removed by cleanup() (the single
# consolidated EXIT/INT/TERM trap installed below). Do NOT add a second
# `trap ... EXIT` here -- the later `trap cleanup EXIT INT TERM` would
# replace it, leaking this file on every run.
MERGED="$(mktemp "${TMPDIR:-/tmp}/claude-vm-merged.XXXXXX.yml")"
claude_vm_merge_config "$GLOBAL_CONFIG" "$REPO_CONFIG" > "$MERGED" \
  || { echo "claude-vm: could not resolve effective config" >&2; exit 1; }

VM_CPUS="$(claude_vm_scalar "$MERGED" '.cpus' "$CLAUDE_VM_DEFAULT_CPUS")"
VM_MEM="$(claude_vm_scalar "$MERGED" '.mem' "$CLAUDE_VM_DEFAULT_MEM")"
REPO_MOUNT="$(claude_vm_scalar "$MERGED" '.repo.mount' "$CLAUDE_VM_DEFAULT_REPO_MOUNT")"
COPY_BACK="$(claude_vm_scalar "$MERGED" '.repo.copy_back' "$CLAUDE_VM_DEFAULT_REPO_COPY_BACK")"
PROXY_PORT="$(claude_vm_scalar "$MERGED" '.proxy.port' "$CLAUDE_VM_DEFAULT_PROXY_PORT")"
GVPROXY_HOST_ALIAS="$(claude_vm_scalar "$MERGED" '.proxy.host_alias' "$CLAUDE_VM_DEFAULT_PROXY_HOST_ALIAS")"
# proxy.cmd: when unset in BOTH config layers, default to the bundled
# tinyproxy launcher (the chosen forward proxy). It reads the egress
# allowlist from $CLAUDE_VM_EGRESS_ALLOWLIST and binds $CLAUDE_VM_PROXY_PORT,
# both exported below. An explicit proxy.cmd in config still overrides it.
DEFAULT_PROXY_CMD="$SCRIPT_DIR/proxy/tinyproxy-launch.sh"
PROXY_CMD="$(claude_vm_scalar "$MERGED" '.proxy.cmd' "$DEFAULT_PROXY_CMD")"

# guest_image: a normal scalar; default to the build/cache location
# alongside the global config dir when unset.
DEFAULT_IMAGE_DIR="$(dirname "$GLOBAL_CONFIG")/images"
GUEST_IMAGE="$(claude_vm_scalar "$MERGED" '.guest_image' "$DEFAULT_IMAGE_DIR/guest.raw")"

# ---------------------------------------------------------------------
# Dependency preflight for the VM toolchain. Fail FAST here -- before any
# build/boot work -- with one actionable remediation per missing piece,
# rather than dying deep in the boot sequence with an opaque error (e.g.
# "gvproxy socket never appeared" when gvproxy is merely off PATH). The
# tinyproxy check is included only when the bundled default proxy is in
# use; a custom proxy.cmd owns its own dependencies.
# ---------------------------------------------------------------------
if [ "$PROXY_CMD" = "$DEFAULT_PROXY_CMD" ]; then
  PREFLIGHT_PROXY_MODE="default-proxy"
else
  PREFLIGHT_PROXY_MODE="custom-proxy"
fi
claude_vm_preflight_toolchain "$PREFLIGHT_PROXY_MODE" \
  || { echo "claude-vm: dependency preflight failed; see the messages above." >&2; exit 1; }

# Resolve gvproxy once, up front. The preflight above already confirmed
# it is resolvable; capture the absolute path so the launch step below
# does not depend on gvproxy being on PATH (it ships inside podman's
# libexec and is not on PATH after a stock 'brew install podman').
GVPROXY_BIN="$(claude_vm_resolve_gvproxy)"

# ---------------------------------------------------------------------
# Ensure guest image exists and matches the pinned version. Build on
# demand rather than erroring. The base is version-pinned; claude is
# NOT baked in -- it is fetched at boot through the egress allowlist.
# ---------------------------------------------------------------------
PINNED_VERSION="$("$SCRIPT_DIR/build-guest-image.sh" --print-version)"
ensure_guest_image() {
  local img="$1" want="$2" have=""
  if [ -f "$img" ] && [ -f "$img.version" ]; then
    have="$(cat "$img.version" 2>/dev/null || true)"
  fi
  if [ "$have" = "$want" ]; then
    return 0
  fi
  echo "claude-vm: guest image missing or version-mismatched (have='${have:-none}', want='$want'); building..." >&2
  mkdir -p "$(dirname "$img")"
  "$SCRIPT_DIR/build-guest-image.sh" --output "$img"
}
ensure_guest_image "$GUEST_IMAGE" "$PINNED_VERSION"

# ---------------------------------------------------------------------
# Run directory + repo mount strategy
# ---------------------------------------------------------------------
# A persistent run id and run dir. When launched from inside a repo,
# the run dir lives under <repo>/.claude/tmp/<runid>/ (git-ignored, and
# persistent so the companion diff/apply skills can extract results).
# Otherwise it falls back to a mktemp dir under TMPDIR.
#
# The run dir and the config dir hold the token-bearing run.env, so they
# must not be world-traversable to that secret. Create them with a
# tightened umask (077 -> drwx------) so the secret's parent dirs are
# owner-only from creation. The umask is restored immediately afterward
# so the umask does NOT bleed into the `git clone` below: a clone under
# umask 077 checks out worktree files as -rw-------, and the later
# copy-back (rsync -a, which preserves perms) would then push 0600 onto
# the user's source files, silently tightening their permissions. Only
# the run.env write itself re-tightens the umask (in a subshell) so the
# secret file is never world-readable, not even momentarily.
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OLD_UMASK="$(umask)"
umask 077
if git -C "$REPO_SRC" rev-parse --show-toplevel >/dev/null 2>&1; then
  RUN="$REPO_SRC/.claude/tmp/$RUN_ID"
  mkdir -p "$RUN"
else
  RUN="$(mktemp -d "${TMPDIR:-/tmp}/claude-vm.XXXXXX")"
fi

GVPROXY_SOCK="$RUN/vfkit-net.sock"
PCAP="$RUN/egress.pcap"
WORKTREE="$RUN/worktree"
CONFIG_DIR="$RUN/config"
EFISTORE="$RUN/efistore"
mkdir -p "$CONFIG_DIR"
# Restore the caller's umask before the clone so cloned worktree files
# keep normal perms (see the umask note above).
umask "$OLD_UMASK"

case "$REPO_MOUNT" in
  clone)
    # Persistent clone -- the guest never touches the live tree or .git.
    git clone --no-hardlinks "$REPO_SRC" "$WORKTREE" >/dev/null
    MOUNT_SHARED_DIR="$WORKTREE"
    ;;
  live)
    # Mount the live repo dir RW directly. Less isolated; opt-in.
    MOUNT_SHARED_DIR="$REPO_SRC"
    ;;
  *)
    echo "claude-vm: unknown repo.mount '$REPO_MOUNT' (expected 'clone' or 'live')" >&2
    exit 1
    ;;
esac

# Record run metadata so companion skills (diff / apply-local /
# apply-remote) can locate the source and worktree after exit.
{
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'repo_src=%s\n' "$REPO_SRC"
  printf 'repo_mount=%s\n' "$REPO_MOUNT"
  printf 'worktree=%s\n' "$MOUNT_SHARED_DIR"
  printf 'copy_back=%s\n' "$COPY_BACK"
} > "$RUN/run.meta"

# ---------------------------------------------------------------------
# Guest run.env -- includes the scoped token (secret). Written inside a
# subshell with umask 077 so the file is created -rw------- with no
# world-readable window (the default umask 022 would create it
# -rw-r--r-- until the chmod). The redirection's target file is created
# by the subshell, so the tightened umask applies to its creation. The
# chmod 600 afterward is belt-and-suspenders. CONFIG_DIR itself is
# already drwx------ (created under the tightened umask above), so the
# secret is not world-traversable either.
# ---------------------------------------------------------------------
RUN_ENV="$CONFIG_DIR/run.env"
(
  umask 077
  {
    printf 'ANTHROPIC_API_KEY=%s\n' "$SCOPED_TOKEN"
    printf 'HTTPS_PROXY=http://%s:%s\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'HTTP_PROXY=http://%s:%s\n' "$GVPROXY_HOST_ALIAS" "$PROXY_PORT"
    printf 'NO_PROXY=localhost,127.0.0.1\n'
    printf 'REPO_TAG=repo\n'
    printf 'POLICY_TAG=policy\n'
    printf 'CLAUDE_ARGS=%s\n' "${CLAUDE_ARGS[*]}"
  } > "$RUN_ENV"
)
chmod 600 "$RUN_ENV"

# ---------------------------------------------------------------------
# Egress allowlist -- write it where the proxy reads it. The proxy.cmd
# is expected to consume CLAUDE_VM_EGRESS_ALLOWLIST (a newline-delimited
# host file) instead of a hand-maintained allowlist baked into the cmd.
# ---------------------------------------------------------------------
EGRESS_ALLOWLIST="$CONFIG_DIR/egress.allow"
claude_vm_egress_hosts "$MERGED" > "$EGRESS_ALLOWLIST"
export CLAUDE_VM_EGRESS_ALLOWLIST="$EGRESS_ALLOWLIST"
# The proxy.cmd must bind the port the guest's HTTPS_PROXY points at (set
# in run.env above). Export it so the bundled tinyproxy launcher -- and any
# override that wants it -- listens on the right port.
export CLAUDE_VM_PROXY_PORT="$PROXY_PORT"

# Guard: an empty effective allowlist means NEITHER config layer set
# egress.allow. Combined with an allow-all proxy default this would
# negate the VM's egress confinement -- the guest could reach anything.
# The proxy.cmd owns the actual fail-open/fail-closed policy, so we do
# not hard-fail here, but the operator must be told egress is unconfined.
if ! grep -q '[^[:space:]]' "$EGRESS_ALLOWLIST" 2>/dev/null; then
  echo "claude-vm: WARNING -- effective egress.allow is EMPTY (no hosts in either config layer)." >&2
  echo "claude-vm: the guest's outbound access is unconfined unless proxy.cmd fails closed on an empty allowlist." >&2
  echo "claude-vm: set egress.allow in ~/.config/claude-vm/config.yml or <repo>/.claude-vm/config.yml to confine egress." >&2
fi

if [ -z "$PROXY_CMD" ]; then
  # proxy.cmd defaults to the bundled tinyproxy launcher; reaching here
  # means a config layer explicitly set proxy.cmd to an empty value.
  echo "claude-vm: proxy.cmd is set to an empty value in config; cannot start the forward proxy." >&2
  echo "claude-vm: leave proxy.cmd unset to use the bundled tinyproxy launcher, or set it" >&2
  echo "claude-vm: to a command that reads \$CLAUDE_VM_EGRESS_ALLOWLIST." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Build extra-mount device flags from config (mounts: list).
# Each entry becomes a virtio-fs device. The repo auto-mount (tag
# 'repo') and the run-config mount (tag 'runconfig') are always added
# below; these are the user's EXTRA mounts.
# ---------------------------------------------------------------------
EXTRA_MOUNT_FLAGS=()
while IFS=$'\t' read -r src tag mode; do
  [ -z "$src" ] && continue
  # Expand a leading ~ to $HOME (config is YAML, not shell).
  case "$src" in
    "~"/*) src="$HOME/${src#"~/"}" ;;
    "~") src="$HOME" ;;
  esac
  # mode is advisory for virtio-fs share dirs; recorded for the guest
  # mount step. vfkit shares the dir; the guest mounts ro/rw per mode.
  EXTRA_MOUNT_FLAGS+=(--device "virtio-fs,sharedDir=$src,mountTag=$tag")
done < <(claude_vm_mount_specs "$MERGED")

# ---------------------------------------------------------------------
# Launch: proxy -> gvproxy -> vfkit. Copy-back on exit (clone mode).
# ---------------------------------------------------------------------
PROXY_PID=""
GV_PID=""

# Is the source working tree dirty (uncommitted tracked changes or
# untracked, non-ignored files)? Returns 0 (dirty) / 1 (clean). A
# non-git source or a git failure is treated as "dirty" so we err on
# the side of NOT clobbering unattended.
src_tree_is_dirty() {
  local status
  git -C "$REPO_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  status="$(git -C "$REPO_SRC" status --porcelain 2>/dev/null)" || return 0
  [ -n "$status" ]
}

# Run the rsync that mirrors the guest worktree back over the source,
# excluding .git so local history/branch state is untouched. rsync
# errors are NOT suppressed -- a failure must be visible. Returns
# rsync's exit status.
copy_back_rsync() {
  rsync -a --exclude '.git' "$WORKTREE"/ "$REPO_SRC"/ \
    || { echo "claude-vm: copy-back failed (rsync); worktree retained at $WORKTREE" >&2; return 1; }
}

copy_back() {
  # Default post-exit behavior: copy the worktree's changes back to the
  # local source. Only meaningful in clone mode (live mode already wrote
  # to the source in place). copy_back=none disables it.
  #
  # Safety: this runs unattended on every trapped exit (including
  # Ctrl-C), so it must never silently clobber uncommitted local edits.
  # It mirrors the safer apply path documented in the
  # claude-vm-apply-local skill: if the local source tree is dirty, it
  # previews what copy-back would change and requires explicit
  # confirmation; if clean, it proceeds (surfacing any rsync error).
  [ "$REPO_MOUNT" = "clone" ] || return 0
  case "$COPY_BACK" in
    none) return 0 ;;
    local|"")
      if src_tree_is_dirty; then
        echo "claude-vm: WARNING -- local source ($REPO_SRC) has uncommitted changes." >&2
        echo "claude-vm: copy-back would overwrite overlapping files. Preview of what it would change:" >&2
        # Show a preview of files copy-back would change, without writing
        # anything. --itemize-changes lists per-file actions; errors are
        # surfaced (no 2>/dev/null). A preview failure is not fatal -- we
        # still fall through to the confirmation prompt.
        rsync -a --dry-run --itemize-changes --exclude '.git' \
          "$WORKTREE"/ "$REPO_SRC"/ >&2 \
          || echo "claude-vm: (could not compute copy-back preview)" >&2
        # Require explicit confirmation. Read from the controlling tty so
        # this works even when invoked from the EXIT/INT trap with stdin
        # consumed. If no usable tty is available (non-interactive, or
        # /dev/tty present but not connected to a terminal), default to
        # SKIP rather than clobber.
        #
        # The `< /dev/tty` open happens before `read` runs, so a stray
        # 2>/dev/null on `read` alone would NOT suppress a failed open
        # ("Device not configured" / "no such device or address") -- the
        # shell opens the redirect and reports that error itself. To
        # actually swallow it, the brace group (which includes the
        # redirect) is what gets 2>/dev/null. A failed open then makes the
        # group fail quietly, the `if` takes the else branch, and reply
        # stays empty -- which routes to SKIP.
        local reply=""
        if [ -t 0 ] || { [ -e /dev/tty ] && [ -r /dev/tty ]; }; then
          printf 'claude-vm: apply copy-back over the dirty source tree? [y/N] ' >&2
          if { read -r reply < /dev/tty; } 2>/dev/null; then :; else reply=""; fi
        fi
        case "$reply" in
          y|Y|yes|YES)
            echo "claude-vm: confirmed; copying back to $REPO_SRC..." >&2
            copy_back_rsync || true
            ;;
          *)
            echo "claude-vm: copy-back SKIPPED; worktree retained at $WORKTREE" >&2
            echo "claude-vm: review with /claude-vm-diff and apply with /claude-vm-apply-local when ready." >&2
            ;;
        esac
      else
        echo "claude-vm: copy-back to local source ($REPO_SRC) from worktree..." >&2
        copy_back_rsync || true
      fi
      ;;
    *)
      echo "claude-vm: unknown repo.copy_back '$COPY_BACK' (expected local|none); skipping" >&2
      ;;
  esac
}

cleanup() {
  [ -n "$GV_PID" ] && kill "$GV_PID" 2>/dev/null || true
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  copy_back
  # Remove the merged-config temp file. Guarded for the case where the
  # trap fires before MERGED is set (it is unset/empty then). Written as
  # an `if` rather than `[ -n ... ] && rm` so a false guard does not make
  # the function return non-zero and trip `set -e` before the echoes below.
  if [ -n "${MERGED:-}" ]; then
    rm -f "$MERGED"
  fi
  echo "claude-vm: egress capture retained at: $PCAP" >&2
  echo "claude-vm: run dir (persistent): $RUN" >&2
}
trap cleanup EXIT INT TERM

# Start the forward proxy. It reads the allowlist from
# $CLAUDE_VM_EGRESS_ALLOWLIST (exported above).
eval "$PROXY_CMD" &
PROXY_PID=$!

"$GVPROXY_BIN" --listen-vfkit "unixgram://$GVPROXY_SOCK" --pcap "$PCAP" &
GV_PID=$!

for _ in $(seq 1 50); do
  [ -S "$GVPROXY_SOCK" ] && break
  sleep 0.1
done
[ -S "$GVPROXY_SOCK" ] || { echo "claude-vm: gvproxy socket never appeared" >&2; exit 1; }

vfkit \
  --cpus "$VM_CPUS" --memory "$VM_MEM" \
  --bootloader "efi,variable-store=$EFISTORE,create" \
  --device "virtio-blk,path=$GUEST_IMAGE" \
  --device "virtio-fs,sharedDir=$MOUNT_SHARED_DIR,mountTag=repo" \
  --device "virtio-fs,sharedDir=$CONFIG_DIR,mountTag=runconfig" \
  ${EXTRA_MOUNT_FLAGS[@]+"${EXTRA_MOUNT_FLAGS[@]}"} \
  --device "virtio-net,unixSocketPath=$GVPROXY_SOCK" \
  --device "virtio-rng"
