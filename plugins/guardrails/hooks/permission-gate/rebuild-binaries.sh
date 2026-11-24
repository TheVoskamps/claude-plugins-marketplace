#!/usr/bin/env bash
# Test, lint and cross-compile the permission gate, then install the
# committed binaries under ../bin/<goos>-<goarch>/.
#
# Usage: rebuild-binaries.sh
#
# Run it on a clean working tree, from any directory. Every target is pure
# Go with CGo disabled, so all of them cross-compile from one host and none
# is built at plugin load time.
#
# Each binary is built into a gitignored scratch directory and copied into
# ../bin/ only once every arch is built and each one stamps
# vcs.modified=false. Go reads vcs.modified from `git status --porcelain`,
# so building straight into ../bin/ would dirty a tracked file with the
# first binary and stamp every later arch vcs.modified=true from committed
# source.
#
# Exit status: 0 when the binaries are installed; 1 on any failure — a test,
# vet, lint, format or build step, a binary stamping anything but
# vcs.modified=false, or a git or filesystem step — with nothing copied into
# ../bin/ unless the copy itself fails, which leaves installed the arches
# copied before it; 2 on a usage error.

set -euo pipefail

# The <goos>-<goarch> set hooks.json selects from by `uname`: macOS on Apple
# Silicon, WSL2, and claude-vm guests (Debian on Apple Silicon). A platform
# missing here has no binary, and hooks.json denies every gated tool call on it.
TARGETS=(darwin-arm64 linux-amd64 linux-arm64)

fail() {
  echo "rebuild-binaries.sh: $1" >&2
  exit 1
}

if [ "$#" -ne 0 ]; then
  echo "rebuild-binaries.sh: takes no arguments." >&2
  exit 2
fi

module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || fail "cannot resolve the script's own directory"
bin_dir=$(cd "$module_dir/../bin" && pwd) || fail "cannot resolve $module_dir/../bin"
repo_root=$(git -C "$module_dir" rev-parse --show-toplevel) ||
  fail "git rev-parse --show-toplevel failed in $module_dir"
scratch="$repo_root/.claude/tmp/rebuild-binaries"

cd "$module_dir" || fail "cannot cd to $module_dir"

go test ./... || fail "go test failed"
go vet ./... || fail "go vet failed"
# golangci-lint discovers the repo-root .golangci.yml upward from here.
golangci-lint run || fail "golangci-lint run reported issues"
fmt_diff=$(golangci-lint fmt --diff) || fail "golangci-lint fmt --diff failed"
if [ -n "$fmt_diff" ]; then
  printf '%s\n' "$fmt_diff" >&2
  fail "golangci-lint fmt --diff reported unformatted source"
fi

rm -rf "$scratch" || fail "cannot remove $scratch"
for target in "${TARGETS[@]}"; do
  goos=${target%-*}
  goarch=${target#*-}
  out="$scratch/$target/permission-gate"
  GOOS=$goos GOARCH=$goarch CGO_ENABLED=0 go build -trimpath -o "$out" . ||
    fail "go build failed for $target"
  buildinfo=$(go version -m "$out") || fail "go version -m failed for $target"
  case "$buildinfo" in
    *$'\tbuild\tvcs.modified=false'*) ;;
    *) fail "$target stamps something other than vcs.modified=false: commit every change, then run again" ;;
  esac
done

for target in "${TARGETS[@]}"; do
  cp "$scratch/$target/permission-gate" "$bin_dir/$target/permission-gate" ||
    fail "copying the $target binary into $bin_dir failed"
  chmod 755 "$bin_dir/$target/permission-gate" || fail "chmod of the $target binary failed"
done
# The binaries are installed, so a scratch directory left behind is reported
# rather than turned into a failure.
rm -rf "$scratch" || echo "rebuild-binaries.sh: could not remove $scratch" >&2

echo "rebuild-binaries.sh: installed ${TARGETS[*]} under $bin_dir"
